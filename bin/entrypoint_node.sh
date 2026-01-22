#!/bin/bash

#Generae random agent name
RANDOM_NAME=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)



export MANAGER_URL="${MANAGER_URL:-localhost}"
export MANAGER_PORT="${MANAGER_PORT:-1515}"
export SERVER_URL="${SERVER_URL:-localhost}"
export SERVER_PORT="${SERVER_PORT:-1514}"
if [ -n "$NAME" ]; then
  export NAME="$NAME"
else
  export NAME="agent-${RANDOM_NAME}"
fi
echo $NAME
export GROUP="${GROUP:-default}"
export ENROL_TOKEN="${ENROL_TOKEN:-}"

echo "Setup register key"
if [ -n "$ENROL_TOKEN" ]; then
  echo -n "$ENROL_TOKEN" > /var/ossec/etc/authd.pass
else
  rm -f /var/ossec/etc/authd.pass
fi

echo "Setup Config"
envsubst < "/opt/ossec/ossec.tpl" > "/var/ossec/etc/ossec.conf"




echo "Startin up Wazuh Client"
/var/ossec/bin/wazuh-control start
echo "Starting Health and Ready"
cd /web && ./ready.sh &



tail -f /var/ossec/logs/*
