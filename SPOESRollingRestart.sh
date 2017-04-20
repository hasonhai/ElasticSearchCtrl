#!/bin/bash
CURDIR=$( dirname $0 )

SERVERLIST="$CURDIR/conf/servers.lst"
IGNORELIST="$CURDIR/conf/ignore.lst"
rdn=$((RANDOM%8+1))
BOOTSTRAP_SERVER="$( sed -ne "${rdn},${rdn}p" $SERVERLIST )" #select random bootstrap server
echo "Selected bootstrap server: $BOOTSTRAP_SERVER"
DOMAIN="spo"
PORT="9200"

# Compare the number of nodes in the ES cluster and the number of node in the SPO cluster
TOTAL_NODES="$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.${DOMAIN}:9200/_cluster/health?pretty" | grep "number_of_nodes" | grep -o '[0-9]\+' )"
echo "Current nodes in the cluster: $TOTAL_NODES"
SPO_NODES="$( wc -l $CURDIR/conf/servers.lst | cut -d' ' -f1 )"
echo "Total nodes: $SPO_NODES"
if [ "$TOTAL_NODES" != "$SPO_NODES" ]; then
    echo "Cluster is not in good shape. Exit now"
    exit 1
fi


for svr in $( cat $SERVERLIST ); do
  echo "We are handling node $svr ================="
  IGNORE=0
  for ignore_svr in $( cat $IGNORELIST ); do
    if [ "$svr" = "$ignore_svr" ]; then
      IGNORE=1
    fi
  done

  if [ "$IGNORE" = "1" ]; then
    echo "Ignoring node $svr"
    continue
  fi

  echo "Stoping $svr"
  sh $CURDIR/SPOESControl.sh stop node $svr
  sleep 10
  echo "Starting $svr"
  sh $CURDIR/SPOESControl.sh start node $svr
  sleep 10

  TOTAL_NODES="$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.${DOMAIN}:9200/_cluster/health?pretty" | grep "number_of_nodes" | grep -o '[0-9]\+' )"
  if [ $TOTAL_NODES -gt $SPO_NODES ]; then
     echo "$svr: Some nodes have multiple elasticsearch deamon"
     echo "$svr: Total nodes is $SPO_NODES but we have now $TOTAL_NODES nodes in the cluster"
     exit 1
  fi
  
  NODE_STATUS="$( curl -s -XGET "http://${svr}.${DOMAIN}:9200/" | grep "status" | grep -o '[0-9]\+' )"
  while [ "$NODE_STATUS" != "200" ]; do
    sleep 10
    echo "$svr: Sleep 10s waiting for node $svr joining the cluster"
    NODE_STATUS="$( curl -s -XGET "http://${svr}:9200/" | grep "status" | grep -o '[0-9]\+' )" 
  done

  CLUSTER_STATUS_GREEN=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "green" )
  while [ "$CLUSTER_STATUS_GREEN" != "1" ]; do # Cluster green
    CLUSTER_STATUS_RED=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "red" )
    if [ "$CLUSTER_STATUS_RED" = "1" ]; then
      echo "$svr: Cluster is in RED state, exit for safety"
      exit 1
    else
      echo "$svr: Cluster status is in YELLOW state, wait 20s for GREEN signal [GREEN = $CLUSTER_STATUS_GREEN]"
      sleep 20
    fi
    CLUSTER_STATUS_GREEN=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "green" )
  done
done

