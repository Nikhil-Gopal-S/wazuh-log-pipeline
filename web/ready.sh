#!/bin/bash
#
# This will read the agent string state and if connected update the helt endpoint.
# Else it will delete the file.
#
# the ready probe will get a http 200 id the status is connected
# the ready probe will get a http 404 if the status is not conne
#
#



echo "Start up Webbserver"
python3 -m http.server "${READY_PORT:-9001}" &



while :
do
        sleep 39
        STATUS=$(grep ^status /var/ossec/var/run/wazuh-agentd.state)
        echo $STATUS
        if [[ "$STATUS" =~ ^(.*)connected ]]; then
                echo "Connected" > /web/ready.html
        else
                echo "Not ready"
                rm /web/ready.html >&- 2>&-
        fi
done
