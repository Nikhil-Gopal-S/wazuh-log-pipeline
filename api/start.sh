#!/bin/bash
echo "Starting api server"
cd /var/ossec/wodles/api/

# Default port
PORT="${API_PORT:-9000}"

CMD="uvicorn api:app --host 0.0.0.0 --port $PORT --proxy-headers"

if [ -n "$SSL_KEY_FILE" ] && [ -n "$SSL_CERT_FILE" ]; then
    echo "SSL configuration detected. Enabling HTTPS."
    CMD="$CMD --ssl-keyfile $SSL_KEY_FILE --ssl-certfile $SSL_CERT_FILE"
else
    echo "No SSL configuration found. Starting in HTTP mode."
fi

exec $CMD
