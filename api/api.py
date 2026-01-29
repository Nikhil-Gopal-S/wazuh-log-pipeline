
import socket
import sys
import logging
import os
import json
import asyncio
import time
import re
import uuid
import secrets
from typing import Union, List, Optional, Dict, Any
from datetime import datetime, timezone

# =============================================================================
# Service Start Time (for uptime calculation)
# =============================================================================
SERVICE_START_TIME = time.time()
SERVICE_VERSION = "1.0.0"

from fastapi import Request, FastAPI, HTTPException, Security, Depends
from fastapi.security.api_key import APIKeyHeader
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.status import HTTP_401_UNAUTHORIZED, HTTP_413_REQUEST_ENTITY_TOO_LARGE, HTTP_504_GATEWAY_TIMEOUT, HTTP_429_TOO_MANY_REQUESTS
from starlette.middleware.base import BaseHTTPMiddleware
from pydantic import BaseModel, Field, validator
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware


# =============================================================================
# Secure Logging Configuration
# =============================================================================

# Log level from environment (default: INFO, never DEBUG in production)
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
# Validate log level - restrict to safe levels
ALLOWED_LOG_LEVELS = {"INFO", "WARNING", "ERROR", "CRITICAL"}
if LOG_LEVEL not in ALLOWED_LOG_LEVELS:
    LOG_LEVEL = "INFO"

# Environment detection for additional safety
IS_PRODUCTION = os.getenv("ENVIRONMENT", "production").lower() == "production"

# Force INFO or higher in production (never DEBUG)
if IS_PRODUCTION and LOG_LEVEL == "DEBUG":
    LOG_LEVEL = "INFO"


class SensitiveDataFilter(logging.Filter):
    """
    Filter to redact sensitive data from log messages.
    
    Filters out:
    - API keys
    - Authorization headers
    - Passwords/secrets
    - Tokens
    - Optionally masks IP addresses in debug mode
    """
    
    SENSITIVE_PATTERNS = [
        # API keys in various formats
        (re.compile(r'api[_-]?key["\']?\s*[:=]\s*["\']?[\w\-]+', re.IGNORECASE), 'api_key=[REDACTED]'),
        (re.compile(r'X-API-Key["\']?\s*[:=]\s*["\']?[\w\-]+', re.IGNORECASE), 'X-API-Key=[REDACTED]'),
        # Authorization headers
        (re.compile(r'authorization["\']?\s*[:=]\s*["\']?[\w\s\-\.]+', re.IGNORECASE), 'authorization=[REDACTED]'),
        (re.compile(r'bearer\s+[\w\-\.]+', re.IGNORECASE), 'Bearer [REDACTED]'),
        # Passwords and secrets
        (re.compile(r'password["\']?\s*[:=]\s*["\']?[^\s,}\]"\']+', re.IGNORECASE), 'password=[REDACTED]'),
        (re.compile(r'secret["\']?\s*[:=]\s*["\']?[^\s,}\]"\']+', re.IGNORECASE), 'secret=[REDACTED]'),
        (re.compile(r'passwd["\']?\s*[:=]\s*["\']?[^\s,}\]"\']+', re.IGNORECASE), 'passwd=[REDACTED]'),
        # Tokens
        (re.compile(r'token["\']?\s*[:=]\s*["\']?[\w\-\.]+', re.IGNORECASE), 'token=[REDACTED]'),
        (re.compile(r'access_token["\']?\s*[:=]\s*["\']?[\w\-\.]+', re.IGNORECASE), 'access_token=[REDACTED]'),
        (re.compile(r'refresh_token["\']?\s*[:=]\s*["\']?[\w\-\.]+', re.IGNORECASE), 'refresh_token=[REDACTED]'),
        # AWS credentials
        (re.compile(r'aws_secret["\']?\s*[:=]\s*["\']?[\w\-\/\+]+', re.IGNORECASE), 'aws_secret=[REDACTED]'),
        (re.compile(r'aws_access_key["\']?\s*[:=]\s*["\']?[\w]+', re.IGNORECASE), 'aws_access_key=[REDACTED]'),
    ]
    
    def __init__(self, mask_ips: bool = False):
        """
        Initialize the filter.
        
        Args:
            mask_ips: If True, mask IP addresses (useful for GDPR compliance)
        """
        super().__init__()
        self.mask_ips = mask_ips
        # IP address pattern for optional masking
        self.ip_pattern = re.compile(r'\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.(\d{1,3})\b')
    
    def filter(self, record: logging.LogRecord) -> bool:
        """Filter and redact sensitive data from log record."""
        # Redact message
        if hasattr(record, 'msg') and isinstance(record.msg, str):
            record.msg = self._redact_sensitive(record.msg)
        
        # Redact args if present
        if record.args:
            if isinstance(record.args, dict):
                record.args = {k: self._redact_sensitive(str(v)) if isinstance(v, str) else v
                              for k, v in record.args.items()}
            elif isinstance(record.args, tuple):
                record.args = tuple(self._redact_sensitive(str(arg)) if isinstance(arg, str) else arg
                                   for arg in record.args)
        
        return True
    
    def _redact_sensitive(self, text: str) -> str:
        """Redact sensitive patterns from text."""
        for pattern, replacement in self.SENSITIVE_PATTERNS:
            text = pattern.sub(replacement, text)
        
        # Optionally mask IP addresses (partial masking for debugging)
        if self.mask_ips:
            text = self.ip_pattern.sub(r'\1.xxx.xxx.\2', text)
        
        return text


class JSONFormatter(logging.Formatter):
    """
    JSON formatter for structured logging.
    
    Produces JSON log entries with consistent fields for easy parsing
    by log aggregation systems (ELK, Splunk, etc.)
    """
    
    def format(self, record: logging.LogRecord) -> str:
        """Format log record as JSON."""
        # Base log data
        log_data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        
        # Add request context if available
        for key in ['request_id', 'client_ip', 'method', 'endpoint', 'status_code', 'duration_ms']:
            if hasattr(record, key):
                value = getattr(record, key)
                # Don't include None values
                if value is not None:
                    log_data[key] = value
        
        # Add exception info if present (but sanitize it)
        if record.exc_info:
            # Only include exception type and message, not full traceback
            exc_type, exc_value, _ = record.exc_info
            if exc_type:
                log_data["exception"] = {
                    "type": exc_type.__name__,
                    "message": str(exc_value) if exc_value else None
                }
        
        # Add any extra fields
        if hasattr(record, 'extra_fields') and isinstance(record.extra_fields, dict):
            log_data.update(record.extra_fields)
        
        return json.dumps(log_data, default=str)


class SecureLoggerAdapter(logging.LoggerAdapter):
    """
    Logger adapter that automatically includes request context.
    
    Usage:
        logger = SecureLoggerAdapter(base_logger, {"request_id": "..."})
        logger.info("Message", extra={"endpoint": "/ingest"})
    """
    
    def process(self, msg, kwargs):
        """Add context to log messages."""
        extra = kwargs.get('extra', {})
        extra.update(self.extra)
        kwargs['extra'] = extra
        return msg, kwargs


def setup_secure_logging() -> logging.Logger:
    """
    Configure secure logging with JSON formatting and sensitive data filtering.
    
    Returns:
        Configured logger instance
    """
    # Create logger
    logger = logging.getLogger("wazuh-ingest-api")
    logger.setLevel(getattr(logging, LOG_LEVEL))
    
    # Remove existing handlers
    logger.handlers.clear()
    
    # Create console handler with JSON formatter
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(getattr(logging, LOG_LEVEL))
    
    # Add sensitive data filter
    sensitive_filter = SensitiveDataFilter(mask_ips=False)
    console_handler.addFilter(sensitive_filter)
    
    # Set JSON formatter
    json_formatter = JSONFormatter()
    console_handler.setFormatter(json_formatter)
    
    # Add handler to logger
    logger.addHandler(console_handler)
    
    # Prevent propagation to root logger
    logger.propagate = False
    
    return logger


# Initialize secure logger
logger = setup_secure_logging()

# =============================================================================
# Request Timeout Configuration (Slow Client Attack Protection)
# =============================================================================
REQUEST_TIMEOUT_SECONDS = int(os.getenv("REQUEST_TIMEOUT_SECONDS", "30"))  # Maximum time for a request to complete
SLOW_REQUEST_THRESHOLD = int(os.getenv("SLOW_REQUEST_THRESHOLD", "5"))     # Log warning for requests taking longer than this

# =============================================================================
# Payload Size Limits (DoS Protection)
# =============================================================================
# Default maximum payload size (10MB)
MAX_CONTENT_LENGTH_DEFAULT = 10 * 1024 * 1024  # 10MB

# Endpoint-specific limits
MAX_CONTENT_LENGTH_INGEST = 1 * 1024 * 1024    # 1MB for single log ingestion
MAX_CONTENT_LENGTH_BATCH = 10 * 1024 * 1024    # 10MB for batch ingestion

try:
    import boto3
except ImportError:
    logger.warning('boto3 module is not installed, but proceeding as it is not strictly required for ingestion.')

# Security: API Key Authentication - MANDATORY
API_KEY_NAME = "X-API-Key"


def read_secret(secret_name: str) -> Optional[str]:
    """
    Read a secret from multiple sources with priority:
    1. Docker secrets (/run/secrets/{secret_name})
    2. Local secrets file (secrets/{secret_name}.txt)
    3. Environment variable ({SECRET_NAME} uppercase)
    
    Returns the secret value or None if not found.
    """
    # Try Docker secrets path first (production)
    docker_secret_path = f"/run/secrets/{secret_name}"
    if os.path.isfile(docker_secret_path):
        try:
            with open(docker_secret_path, 'r') as f:
                secret = f.read().strip()
                if secret:
                    logger.info(f"Secret '{secret_name}' loaded from Docker secrets")
                    return secret
        except IOError as e:
            logger.warning(f"Failed to read Docker secret '{secret_name}': {e}")
    
    # Try local secrets file (development)
    local_secret_path = f"secrets/{secret_name}.txt"
    if os.path.isfile(local_secret_path):
        try:
            with open(local_secret_path, 'r') as f:
                secret = f.read().strip()
                if secret:
                    logger.info(f"Secret '{secret_name}' loaded from local file")
                    return secret
        except IOError as e:
            logger.warning(f"Failed to read local secret '{secret_name}': {e}")
    
    # Fallback to environment variable
    env_var_name = secret_name.upper()
    secret = os.environ.get(env_var_name)
    if secret:
        logger.info(f"Secret '{secret_name}' loaded from environment variable")
        return secret
    
    return None


# Load API key from secrets (file-based or environment variable)
API_KEY = read_secret("api_key")

# Startup validation: Fail if API_KEY is not found from any source
if not API_KEY:
    raise RuntimeError(
        "FATAL: API_KEY not found. Please provide it via:\n"
        "  1. Docker secret at /run/secrets/api_key\n"
        "  2. Local file at secrets/api_key.txt\n"
        "  3. Environment variable API_KEY"
    )

logger.info("API key authentication enabled successfully.")

# =============================================================================
# Certificate Validation (Production Safety)
# =============================================================================
def check_certificate_validity():
    """
    Check if TLS certificates are self-signed and warn in production.
    
    This function helps prevent accidental production deployment with
    self-signed certificates, which would:
    - Cause browser/client certificate warnings
    - Enable man-in-the-middle attacks if clients disable verification
    - Prevent Cloudflare "Full (Strict)" SSL mode
    """
    cert_path = os.getenv("SSL_CERT_PATH", "/etc/nginx/certs/server.crt")
    is_production = os.getenv("ENVIRONMENT", "development").lower() == "production"
    strict_tls = os.getenv("STRICT_TLS_CHECK", "false").lower() == "true"
    
    if not os.path.exists(cert_path):
        logger.info(f"Certificate path {cert_path} not found - skipping validation")
        return
    
    try:
        # Try to use cryptography library if available
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        
        with open(cert_path, 'rb') as f:
            cert_data = f.read()
        
        cert = x509.load_pem_x509_certificate(cert_data, default_backend())
        
        # Check if self-signed (issuer == subject)
        is_self_signed = cert.issuer == cert.subject
        
        # Check certificate expiry
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        days_until_expiry = (cert.not_valid_after_utc - now).days
        
        if is_self_signed:
            warning_msg = (
                "SECURITY WARNING: Self-signed TLS certificate detected! "
                "For production deployment, use a valid CA-signed certificate. "
                "Self-signed certificates enable man-in-the-middle attacks "
                "and prevent Cloudflare 'Full (Strict)' SSL mode."
            )
            if is_production:
                logger.warning(warning_msg)
                if strict_tls:
                    raise RuntimeError(
                        "Self-signed certificate not allowed in production with STRICT_TLS_CHECK=true"
                    )
            else:
                logger.info(f"Self-signed certificate detected (OK for development)")
        
        if days_until_expiry <= 30:
            logger.warning(
                f"TLS certificate expires in {days_until_expiry} days! "
                "Run scripts/rotate-certs.sh to renew."
            )
        elif days_until_expiry <= 7:
            logger.error(
                f"CRITICAL: TLS certificate expires in {days_until_expiry} days! "
                "Immediate renewal required."
            )
        else:
            logger.info(f"TLS certificate valid for {days_until_expiry} days")
            
    except ImportError:
        logger.debug(
            "cryptography module not installed - skipping certificate validation. "
            "Install with: pip install cryptography"
        )
    except Exception as e:
        logger.warning(f"Could not validate certificate: {type(e).__name__}: {e}")


# Run certificate check at module load time
check_certificate_validity()

# Initialize Rate Limiter
# Uses get_remote_address which relies on request.client.host
# Since we use uvicorn --proxy-headers, this will correctly identify the real client IP
limiter = Limiter(key_func=get_remote_address)

app = FastAPI(title="Wazuh Ingestion API", version="1.0.0")
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


# =============================================================================
# Pydantic Models for Request Validation
# =============================================================================

class IngestEvent(BaseModel):
    """Model for a single log event to be ingested."""
    
    # Required fields
    timestamp: str = Field(
        ...,
        description="Event timestamp in ISO 8601 format",
        example="2024-01-15T10:30:00Z"
    )
    source: str = Field(
        ...,
        min_length=1,
        max_length=256,
        description="Source of the log event",
        example="application-server-01"
    )
    message: str = Field(
        ...,
        min_length=1,
        max_length=65536,
        description="Log message content",
        example="User login successful"
    )
    
    # Optional fields with defaults
    level: Optional[str] = Field(
        default="info",
        description="Log level (debug, info, warning, error, critical)",
        example="info"
    )
    tags: Optional[List[str]] = Field(
        default=[],
        description="Optional tags for categorization",
        example=["auth", "security"]
    )
    metadata: Optional[Dict[str, Any]] = Field(
        default={},
        description="Additional metadata as key-value pairs",
        example={"user_id": "12345", "ip": "192.168.1.1"}
    )
    decoder: Optional[str] = Field(
        default=None,
        max_length=128,
        description="Optional decoder name for Wazuh",
        example="custom-decoder"
    )
    
    # Validators
    @validator('level')
    def validate_level(cls, v):
        allowed_levels = ['debug', 'info', 'warning', 'error', 'critical']
        if v and v.lower() not in allowed_levels:
            raise ValueError(f"Level must be one of: {', '.join(allowed_levels)}")
        return v.lower() if v else 'info'
    
    @validator('timestamp')
    def validate_timestamp(cls, v):
        # Basic timestamp validation
        if not v or len(v) < 10:
            raise ValueError("Invalid timestamp format")
        return v
    
    @validator('tags', pre=True, always=True)
    def validate_tags(cls, v):
        if v is None:
            return []
        if not isinstance(v, list):
            raise ValueError("Tags must be a list")
        # Validate each tag
        for tag in v:
            if not isinstance(tag, str) or len(tag) > 64:
                raise ValueError("Each tag must be a string with max 64 characters")
        return v
    
    class Config:
        # Allow extra fields to be ignored (for forward compatibility)
        extra = 'ignore'
        # Generate JSON schema
        schema_extra = {
            "example": {
                "timestamp": "2024-01-15T10:30:00Z",
                "source": "web-server-01",
                "message": "Request processed successfully",
                "level": "info",
                "tags": ["http", "request"],
                "metadata": {"status_code": 200}
            }
        }


class BatchIngestRequest(BaseModel):
    """Model for batch log ingestion."""
    
    events: List[IngestEvent] = Field(
        ...,
        min_items=1,
        max_items=1000,
        description="List of events to ingest (1-1000 events)"
    )
    
    class Config:
        schema_extra = {
            "example": {
                "events": [
                    {
                        "timestamp": "2024-01-15T10:30:00Z",
                        "source": "web-server-01",
                        "message": "Request 1"
                    },
                    {
                        "timestamp": "2024-01-15T10:30:01Z",
                        "source": "web-server-01",
                        "message": "Request 2"
                    }
                ]
            }
        }


# =============================================================================
# Request ID Middleware (Request Tracking & Correlation)
# =============================================================================
class RequestIDMiddleware(BaseHTTPMiddleware):
    """
    Middleware to generate and track unique request IDs.
    
    Each request gets a unique UUID that is:
    - Stored in request.state.request_id
    - Included in all log entries
    - Returned in X-Request-ID response header
    
    This enables request correlation across logs and debugging.
    """
    
    async def dispatch(self, request: Request, call_next):
        # Generate unique request ID
        request_id = str(uuid.uuid4())
        
        # Store in request state for access by other middleware/handlers
        request.state.request_id = request_id
        
        # Process request
        response = await call_next(request)
        
        # Add request ID to response headers
        response.headers["X-Request-ID"] = request_id
        
        return response


def get_request_id(request: Request) -> str:
    """Get request ID from request state, or generate a new one."""
    return getattr(request.state, 'request_id', str(uuid.uuid4()))


def log_with_context(
    level: str,
    message: str,
    request: Optional[Request] = None,
    **extra_fields
) -> None:
    """
    Log a message with request context.
    
    Args:
        level: Log level (info, warning, error, etc.)
        message: Log message
        request: Optional FastAPI request object for context
        **extra_fields: Additional fields to include in log
    """
    extra = {}
    
    if request:
        extra['request_id'] = get_request_id(request)
        extra['client_ip'] = request.client.host if request.client else "unknown"
        extra['method'] = request.method
        extra['endpoint'] = request.url.path
    
    extra.update(extra_fields)
    
    log_method = getattr(logger, level.lower(), logger.info)
    log_method(message, extra=extra)


# =============================================================================
# Request Timeout Middleware (Slow Client Attack Protection)
# =============================================================================
class RequestTimeoutMiddleware(BaseHTTPMiddleware):
    """
    Middleware to enforce request timeouts and track slow requests.
    
    Protects against slow client attacks (Slowloris, slow POST, etc.) by
    enforcing a maximum processing time for each request.
    
    Configuration:
    - REQUEST_TIMEOUT_SECONDS: Maximum time for a request to complete (default: 30s)
    - SLOW_REQUEST_THRESHOLD: Log warning for requests taking longer than this (default: 5s)
    """
    
    async def dispatch(self, request: Request, call_next):
        start_time = time.time()
        request_id = get_request_id(request)
        client_ip = request.client.host if request.client else "unknown"
        
        try:
            # Wrap the request processing with a timeout
            response = await asyncio.wait_for(
                call_next(request),
                timeout=REQUEST_TIMEOUT_SECONDS
            )
            
            # Calculate request duration
            duration = time.time() - start_time
            duration_ms = int(duration * 1000)
            
            # Log slow requests with structured context
            if duration > SLOW_REQUEST_THRESHOLD:
                log_with_context(
                    "warning",
                    "Slow request detected",
                    request,
                    duration_ms=duration_ms,
                    threshold_ms=SLOW_REQUEST_THRESHOLD * 1000
                )
            
            # Add timing header to response
            response.headers["X-Request-Duration"] = f"{duration:.3f}s"
            
            return response
            
        except asyncio.TimeoutError:
            duration = time.time() - start_time
            duration_ms = int(duration * 1000)
            
            log_with_context(
                "error",
                "Request timeout exceeded",
                request,
                duration_ms=duration_ms,
                timeout_seconds=REQUEST_TIMEOUT_SECONDS
            )
            
            return JSONResponse(
                status_code=HTTP_504_GATEWAY_TIMEOUT,
                content={
                    "error": "Gateway Timeout",
                    "message": "Request processing time exceeded",
                    "request_id": request_id
                },
                headers={"X-Request-ID": request_id}
            )


# =============================================================================
# Payload Size Limit Middleware (DoS Protection)
# =============================================================================
class PayloadSizeLimitMiddleware(BaseHTTPMiddleware):
    """
    Middleware to enforce payload size limits.
    
    Protects against denial of service attacks by rejecting requests
    with payloads that exceed configured size limits.
    
    Limits:
    - /batch endpoints: 10MB (for batch log ingestion)
    - / (ingest) endpoint: 1MB (for single log ingestion)
    - Other endpoints: 10MB (default)
    """
    
    async def dispatch(self, request: Request, call_next):
        # Get Content-Length header
        content_length = request.headers.get("content-length")
        request_id = get_request_id(request)
        
        if content_length:
            try:
                content_length = int(content_length)
            except ValueError:
                # Invalid Content-Length header
                log_with_context(
                    "warning",
                    "Invalid Content-Length header received",
                    request
                )
                return JSONResponse(
                    status_code=400,
                    content={
                        "error": "Bad Request",
                        "message": "Invalid Content-Length header",
                        "request_id": request_id
                    },
                    headers={"X-Request-ID": request_id}
                )
            
            # Determine limit based on endpoint
            path = request.url.path
            if "/batch" in path:
                max_size = MAX_CONTENT_LENGTH_BATCH
                endpoint_type = "batch"
            elif path == "/" or "/ingest" in path:
                max_size = MAX_CONTENT_LENGTH_INGEST
                endpoint_type = "ingest"
            else:
                max_size = MAX_CONTENT_LENGTH_DEFAULT
                endpoint_type = "default"
            
            if content_length > max_size:
                log_with_context(
                    "warning",
                    "Payload size limit exceeded",
                    request,
                    content_length=content_length,
                    max_size=max_size,
                    endpoint_type=endpoint_type
                )
                return JSONResponse(
                    status_code=HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    content={
                        "error": "Payload Too Large",
                        "message": "Request body exceeds maximum allowed size",
                        "request_id": request_id
                    },
                    headers={"X-Request-ID": request_id}
                )
        
        return await call_next(request)


# Register middleware (order matters - request ID should be outermost)
# Middleware is executed in reverse order of registration:
# 1. RequestIDMiddleware (registered last, executed first - outermost)
# 2. RequestTimeoutMiddleware (executed second)
# 3. SlowAPIMiddleware (executed third)
# 4. PayloadSizeLimitMiddleware (registered first, executed last - innermost)
app.add_middleware(PayloadSizeLimitMiddleware)
app.add_middleware(SlowAPIMiddleware)
app.add_middleware(RequestTimeoutMiddleware)
app.add_middleware(RequestIDMiddleware)

logger.info(
    "Secure middleware stack initialized",
    extra={
        "timeout_seconds": REQUEST_TIMEOUT_SECONDS,
        "slow_threshold_seconds": SLOW_REQUEST_THRESHOLD,
        "log_level": LOG_LEVEL
    }
)


# =============================================================================
# Custom Exception Handlers (Sanitized Error Responses)
# =============================================================================

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """
    Custom handler for validation errors with sanitized error messages.
    
    - Logs full details server-side
    - Returns sanitized response to client (no internal paths)
    """
    request_id = get_request_id(request)
    
    # Sanitize errors for client response (remove internal details)
    client_errors = []
    server_errors = []
    
    for error in exc.errors():
        # Full error for server logs
        server_errors.append({
            "field": ".".join(str(loc) for loc in error["loc"]),
            "message": error["msg"],
            "type": error["type"]
        })
        
        # Sanitized error for client (remove potential path info)
        field_path = ".".join(str(loc) for loc in error["loc"] if loc != "body")
        client_errors.append({
            "field": field_path,
            "message": _sanitize_error_message(error["msg"])
        })
    
    # Log full details server-side
    log_with_context(
        "warning",
        "Request validation failed",
        request,
        error_count=len(server_errors),
        errors=server_errors
    )
    
    return JSONResponse(
        status_code=400,
        content={
            "error": "Validation Error",
            "message": "Request payload validation failed",
            "details": client_errors,
            "request_id": request_id
        },
        headers={"X-Request-ID": request_id}
    )


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """
    Custom handler for HTTP exceptions with sanitized responses.
    
    Ensures consistent error format and includes request ID.
    """
    request_id = get_request_id(request)
    
    # Log the exception server-side
    log_with_context(
        "warning" if exc.status_code < 500 else "error",
        f"HTTP {exc.status_code} error",
        request,
        status_code=exc.status_code
    )
    
    # Sanitize the detail for client response
    detail = exc.detail
    if isinstance(detail, dict):
        message = detail.get("message", detail.get("error", "An error occurred"))
    else:
        message = str(detail) if detail else "An error occurred"
    
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": _get_error_name(exc.status_code),
            "message": _sanitize_error_message(message),
            "request_id": request_id
        },
        headers={"X-Request-ID": request_id}
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    """
    Catch-all handler for unhandled exceptions.
    
    - Logs full exception details server-side (including traceback)
    - Returns generic error to client (no internal details exposed)
    """
    request_id = get_request_id(request)
    
    # Log full exception details server-side
    logger.error(
        "Unhandled exception occurred",
        extra={
            "request_id": request_id,
            "client_ip": request.client.host if request.client else "unknown",
            "method": request.method,
            "endpoint": request.url.path,
            "exception_type": type(exc).__name__,
            "exception_message": str(exc)
        },
        exc_info=True  # Include traceback in server logs
    )
    
    # Return generic error to client (no internal details)
    return JSONResponse(
        status_code=500,
        content={
            "error": "Internal Server Error",
            "message": "An unexpected error occurred. Please try again later.",
            "request_id": request_id
        },
        headers={"X-Request-ID": request_id}
    )


def _sanitize_error_message(message: str) -> str:
    """
    Sanitize error messages to remove sensitive information.
    
    Removes:
    - File paths
    - Line numbers
    - Internal module names
    - Stack trace references
    """
    if not message:
        return "An error occurred"
    
    # Remove file paths (Unix and Windows)
    message = re.sub(r'(/[\w\-./]+\.py)', '[file]', message)
    message = re.sub(r'([A-Za-z]:\\[\w\-\\]+\.py)', '[file]', message)
    
    # Remove line numbers
    message = re.sub(r'line \d+', 'line [N]', message, flags=re.IGNORECASE)
    
    # Remove module references
    message = re.sub(r'in module [\w.]+', 'in module [M]', message)
    
    # Remove memory addresses
    message = re.sub(r'0x[0-9a-fA-F]+', '[addr]', message)
    
    return message


def _get_error_name(status_code: int) -> str:
    """Get human-readable error name for HTTP status code."""
    error_names = {
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        408: "Request Timeout",
        413: "Payload Too Large",
        422: "Unprocessable Entity",
        429: "Too Many Requests",
        500: "Internal Server Error",
        502: "Bad Gateway",
        503: "Service Unavailable",
        504: "Gateway Timeout"
    }
    return error_names.get(status_code, "Error")


api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=False)


async def get_api_key(request: Request, api_key_header: str = Security(api_key_header)):
    """
    Validate API key from request header.
    
    Returns 401 Unauthorized for missing or invalid API keys.
    Logs authentication failures with request context.
    """
    if not api_key_header:
        log_with_context(
            "warning",
            "API request rejected: Missing API key",
            request
        )
        raise HTTPException(
            status_code=HTTP_401_UNAUTHORIZED,
            detail={"error": "Authentication required"}
        )
    
    if not secrets.compare_digest(api_key_header, API_KEY):
        log_with_context(
            "warning",
            "API request rejected: Invalid API key",
            request
        )
        raise HTTPException(
            status_code=HTTP_401_UNAUTHORIZED,
            detail={"error": "Invalid credentials"}
        )
    
    return api_key_header

def send_msg(msg: dict, request_id: Optional[str] = None):
    """
    Sends an event to the Wazuh Queue.
    
    Args:
        msg: Event data to send
        request_id: Optional request ID for log correlation
    
    Returns:
        Dict with status and message
    """
    
    # Determine decoder header
    # Default to Wazuh-AWS if not specified, or use environment override
    default_header = os.getenv("WAZUH_DECODER_HEADER", "1:Wazuh-AWS:")
    
    if 'decoder' in msg:
        message_header = "1:{0}:".format(msg['decoder'])
    else:
        message_header = default_header

    msg['ingest'] = "api"
    
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        # Verify socket path exists
        socket_path = "/var/ossec/queue/sockets/queue"
        if not os.path.exists(socket_path):
            logger.error(
                "Wazuh socket not available",
                extra={"request_id": request_id, "socket_path": "[internal]"}
            )
            return {"status": "error", "message": "Backend service unavailable"}

        s.connect(socket_path)
        
        # Format message
        json_msg = json.dumps(msg)
        full_message = "{header}{msg}".format(header=message_header, msg=json_msg)
        
        encoded_msg = full_message.encode()

        s.send(encoded_msg)
        s.close()
        return {"status": "success", "message": "Event sent to Wazuh"}
        
    except socket.error as e:
        # Log full error server-side, return sanitized message to client
        logger.error(
            "Socket communication error",
            extra={
                "request_id": request_id,
                "error_code": e.errno,
                "error_type": "socket_error"
            }
        )
        
        if e.errno == 111:
            return {"status": "error", "message": "Backend service unavailable"}
        elif e.errno == 90:
            return {"status": "error", "message": "Message exceeds size limit"}
        else:
            return {"status": "error", "message": "Communication error"}
            
    except Exception as e:
        # Log full exception server-side
        logger.error(
            "Unexpected error in message delivery",
            extra={
                "request_id": request_id,
                "exception_type": type(e).__name__
            },
            exc_info=True
        )
        return {"status": "error", "message": "An unexpected error occurred"}


# =============================================================================
# Health Check Helper Functions
# =============================================================================

def get_uptime() -> float:
    """
    Calculate the service uptime in seconds.
    
    Returns:
        Number of seconds since the service started.
    """
    return time.time() - SERVICE_START_TIME


def check_wazuh_socket() -> bool:
    """
    Check if the Wazuh socket is available and connectable.
    
    Returns:
        True if the socket exists and can be connected to, False otherwise.
    """
    socket_path = "/var/ossec/queue/sockets/queue"
    
    # First check if the socket file exists
    if not os.path.exists(socket_path):
        return False
    
    # Try to connect to verify it's actually working
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.settimeout(2.0)  # 2 second timeout for connection test
        s.connect(socket_path)
        s.close()
        return True
    except (socket.error, OSError):
        return False


# =============================================================================
# Health Check Endpoints
# =============================================================================

@app.get("/health/live")
async def liveness_probe():
    """
    Kubernetes liveness probe endpoint.
    
    Returns a simple 200 OK response to indicate the service is running.
    No authentication required - this is intentional for Kubernetes probes.
    
    Use this endpoint for:
    - Kubernetes livenessProbe
    - Basic service availability checks
    - Load balancer health checks
    """
    return {"status": "alive"}


@app.get("/health/ready")
async def readiness_probe():
    """
    Kubernetes readiness probe endpoint.
    
    Checks if the service is ready to accept traffic by verifying:
    - Wazuh socket connectivity
    
    Returns 200 if ready, 503 if not ready.
    No authentication required - this is intentional for Kubernetes probes.
    
    Use this endpoint for:
    - Kubernetes readinessProbe
    - Load balancer health checks before routing traffic
    """
    if check_wazuh_socket():
        return {"status": "ready", "wazuh_socket": "connected"}
    else:
        raise HTTPException(
            status_code=503,
            detail={
                "status": "not_ready",
                "wazuh_socket": "disconnected",
                "message": "Service is not ready to accept traffic"
            }
        )


@app.get("/health", dependencies=[Depends(get_api_key)])
async def health_check(request: Request):
    """
    Comprehensive health check endpoint with detailed status information.
    
    Requires API key authentication.
    
    Returns detailed information about:
    - Service status (healthy/unhealthy)
    - Service name and version
    - Uptime in seconds
    - Wazuh socket connectivity status
    - Current timestamp
    - Request ID for correlation
    """
    request_id = get_request_id(request)
    wazuh_connected = check_wazuh_socket()
    uptime_seconds = get_uptime()
    
    # Determine overall health status
    status = "healthy" if wazuh_connected else "unhealthy"
    
    # Log health check
    if wazuh_connected:
        log_with_context("info", "Health check: healthy", request)
    else:
        log_with_context("warning", "Health check: unhealthy - socket disconnected", request)
    
    return {
        "status": status,
        "service": "wazuh-api",
        "version": SERVICE_VERSION,
        "uptime_seconds": round(uptime_seconds, 2),
        "wazuh_socket": "connected" if wazuh_connected else "disconnected",
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "request_id": request_id
    }


@app.post("/ingest", dependencies=[Depends(get_api_key)])
async def ingest_event(request: Request, event: IngestEvent):
    """
    Ingest a single log event.
    
    The event is validated against the IngestEvent schema before processing.
    Required fields: timestamp, source, message
    Optional fields: level, tags, metadata, decoder
    """
    request_id = get_request_id(request)
    
    # Convert Pydantic model to dict for send_msg
    event_data = event.dict(exclude_none=True)
    result = send_msg(event_data, request_id)
    
    # Add request ID to response
    result["request_id"] = request_id
    
    # Log successful ingestion
    if result.get("status") == "success":
        log_with_context(
            "info",
            "Event ingested successfully",
            request,
            source=event.source
        )
    
    return result


@app.post("/batch", dependencies=[Depends(get_api_key)])
@limiter.limit("100/minute")
async def ingest_batch(request: Request, batch: BatchIngestRequest):
    """
    Ingest multiple log events in a batch.
    
    Each event in the batch is validated against the IngestEvent schema.
    Maximum 1000 events per batch.
    """
    request_id = get_request_id(request)
    results = []
    error_count = 0
    
    for event in batch.events:
        # Convert Pydantic model to dict for send_msg
        event_data = event.dict(exclude_none=True)
        res = send_msg(event_data, request_id)
        if res.get("status") == "error":
            error_count += 1
        results.append(res)
    
    # Log batch processing summary
    log_with_context(
        "info",
        "Batch processing completed",
        request,
        total_events=len(batch.events),
        error_count=error_count,
        success_count=len(batch.events) - error_count
    )
    
    return {
        "status": "batch_processed",
        "total": len(batch.events),
        "errors": error_count,
        "details": results,
        "request_id": request_id
    }

