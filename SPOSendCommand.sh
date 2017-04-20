#/bin/bash

# Send command to each server in cluster
# command <user> <key> <server list file> "command to run"
SERVERLIST=$(cat $3)
echo We are at server $(hostname)
for SERVER in $SERVERLIST
do
    echo Send command to server $SERVER
    ssh -tt -i $2 $1@$SERVER "$4"
done

