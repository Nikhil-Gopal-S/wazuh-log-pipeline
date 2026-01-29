#!/bin/bash
# Uvicorn startup script with security configurations
echo "Starting api server"
cd /var/ossec/wodles/api/

# Default port
PORT="${API_PORT:-9000}"

# Security and performance configuration
# --timeout-keep-alive: Close idle connections after 5 seconds (prevents slow client attacks)
# --limit-concurrency: Maximum concurrent connections (prevents resource exhaustion)
# --limit-max-requests: Restart worker after N requests (memory leak protection)
TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-5}"
LIMIT_CONCURRENCY="${UVICORN_LIMIT_CONCURRENCY:-100}"
LIMIT_MAX_REQUESTS="${UVICORN_LIMIT_MAX_REQUESTS:-10000}"

CMD="uvicorn api:app --host 0.0.0.0 --port $PORT --proxy-headers"
CMD="$CMD --timeout-keep-alive $TIMEOUT_KEEP_ALIVE"
CMD="$CMD --limit-concurrency $LIMIT_CONCURRENCY"
CMD="$CMD --limit-max-requests $LIMIT_MAX_REQUESTS"
CMD="$CMD --access-log"
CMD="$CMD --log-level info"

if [ -n "$SSL_KEY_FILE" ] && [ -n "$SSL_CERT_FILE" ]; then
    echo "SSL configuration detected. Enabling HTTPS."
    CMD="$CMD --ssl-keyfile $SSL_KEY_FILE --ssl-certfile $SSL_CERT_FILE"
else
    echo "No SSL configuration found. Starting in HTTP mode."
fi

echo "Uvicorn config: timeout-keep-alive=$TIMEOUT_KEEP_ALIVE, limit-concurrency=$LIMIT_CONCURRENCY, limit-max-requests=$LIMIT_MAX_REQUESTS"
exec $CMD
