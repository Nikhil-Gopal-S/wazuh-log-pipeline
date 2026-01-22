
import socket
import sys
import logging
import os
import json
from typing import Union, List, Optional

from fastapi import Request, FastAPI, HTTPException, Security, Depends
from fastapi.security.api_key import APIKeyHeader
from starlette.status import HTTP_403_FORBIDDEN

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("wazuh-ingest-api")

try:
    import boto3
except ImportError:
    logger.warning('boto3 module is not installed, but proceeding as it is not strictly required for ingestion.')

app = FastAPI(title="Wazuh Ingestion API", version="1.0.0")

# Security: API Key Authentication
API_KEY_NAME = "X-API-Key"
API_KEY = os.getenv("API_KEY")

api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=False)

async def get_api_key(api_key_header: str = Security(api_key_header)):
    if not API_KEY:
        # If no API key is set in environment, allow all (Development mode warning)
        logger.warning("Running without API_KEY security! Set API_KEY environment variable.")
        return None
    
    if api_key_header == API_KEY:
        return api_key_header
    else:
        raise HTTPException(
            status_code=HTTP_403_FORBIDDEN, detail="Could not validate credentials"
        )

def send_msg(msg: dict):
    """
    Sends an event to the Wazuh Queue
    """
    
    # Determine decoder header
    # Default to Wazuh-AWS if not specified, or use environment override
    default_header = os.getenv("WAZUH_DECODER_HEADER", "1:Wazuh-AWS:")
    
    if 'decoder' in msg:
        message_header = "1:{0}:".format(msg['decoder'])
    else:
        message_header = default_header

    logger.debug(f"Message header: {message_header}")
    msg['ingest'] = "api"
    
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        # Verify socket path exists
        socket_path = "/var/ossec/queue/sockets/queue"
        if not os.path.exists(socket_path):
            logger.error(f"Wazuh socket not found at {socket_path}")
            return {"status": "error", "message": "Wazuh agent is not running or socket is missing"}

        s.connect(socket_path)
        
        # Format message
        json_msg = json.dumps(msg)
        full_message = "{header}{msg}".format(header=message_header, msg=json_msg)
        
        logger.debug(f"Sending message: {full_message[:100]}...") # Log first 100 chars
        encoded_msg = full_message.encode()

        s.send(encoded_msg)
        s.close()
        return {"status": "success", "message": "Event sent to Wazuh"}
        
    except socket.error as e:
        if e.errno == 111:
            logger.error("Connection refused. Wazuh must be running.")
            return {"status": "error", "message": "Wazuh must be running."}
        elif e.errno == 90:
            logger.error("Message too long for Wazuh buffer.")
            return {"status": "error", "message": "Message too long"}
        else:
            logger.error(f"Socket error: {e}")
            return {"status": "error", "message": f"Socket error: {str(e)}"}
    except Exception as e:
        logger.exception("Unexpected error sending message")
        return {"status": "error", "message": str(e)}


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    socket_path = "/var/ossec/queue/sockets/queue"
    if os.path.exists(socket_path):
        return {"status": "healthy", "wazuh_socket": "connected"}
    return {"status": "unhealthy", "wazuh_socket": "disconnected"}


@app.put("/", dependencies=[Depends(get_api_key)])
async def ingest_event(request: Request):
    try:
        json_data = await request.json()
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON payload")
        
    return send_msg(json_data)


@app.put("/batch", dependencies=[Depends(get_api_key)])
async def ingest_batch(request: Request):
    try:
        json_data = await request.json()
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON payload")
        
    if not isinstance(json_data, list):
         raise HTTPException(status_code=400, detail="Batch endpoint expects a JSON list")

    results = []
    error_count = 0
    
    for data in json_data:
        res = send_msg(data)
        if res.get("status") == "error":
            error_count += 1
        results.append(res)
    
    return {
        "status": "batch_processed", 
        "total": len(json_data), 
        "errors": error_count,
        "details": results
    }

