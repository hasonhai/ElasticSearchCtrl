#/bin/bash

# Distribute file to each server in the cluster
# Server list is put into the file "servers" at the same directory
# Usage: SPODistributeFile <key> <servers-list> <file-to-distribute> <path-to-store-on-servers>
echo We are at server $(hostname)
SERVERLIST=$(cat $2)
for SERVER in $SERVERLIST
do
    echo Distribute file to server $SERVER
    scp -i $1 $3 root@$SERVER:$4
done

