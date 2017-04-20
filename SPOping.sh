#/bin/bash

# Ping each server in cluster
echo We are at server $(hostname)
SERVERLIST=$(cat conf/servers.lst)
for SERVER in $SERVERLIST
do
    echo Ping server $SERVER
    ping -c 3 $SERVER
done

