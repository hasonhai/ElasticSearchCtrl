#!/bin/bash
# Script to start/stop the Elastic Search Cluster on SPO ternant
# Usage:
#               SPOESControl.sh <start|stop|status|keeprunning> [force]

InsDir="$(dirname $0)"
## Set by user
USERNAME="centos"
SERVERLIST="$InsDir/conf/servers.lst"
IGNORELIST="$InsDir/conf/ignore.lst"
KEY="/home/$USERNAME/Keypair/$USERNAME.pem"
DOMAIN="spo"
SPO_NODES=$( wc -l $SERVERLIST | grep -o '[0-9]\+')
rdn=$((RANDOM%${SPO_NODES}+1))
BOOTSTRAP_SERVER="$( sed -ne "${rdn},${rdn}p" $SERVERLIST )" #select random bootstrap server
PORT=9200
LOG="$InsDir/keeprunning.log"
############################
COMMAND="$1"

############################
if [ -e $InsDir/.autolock ]; then
  echo "There is instance running. Exit now."
  echo "If this is a mistake, remove $InsDir/.autolock to fix"
  exit 1;
else
  echo "lock" > $InsDir/.autolock
fi

usage(){
    echo "Usage: $0 <keep-running>"
    echo "       $0 <start|stop|status|> [all|force]"
    echo "       $0 <start|stop|status|> node <nodename>"
    echo "all:   start/stop/check all nodes"
    echo "force: start/stop/check all nodes, but forcefully"
    echo "       handle each one and make sure it is in service"
    echo "node:  start/stop/check one node with a specified name"
}

if [ $# -gt 3 -o $# -lt 1 ]; then
    usage
    rm $InsDir/.autolock
    exit 1
fi

# set mode to run
if [ "$2" = "force" ]; then
    MODE="force"
elif [ "$2" = "node" ]; then
    MODE="node"
    FOUND=0
    for NODE in $( cat $SERVERLIST ); do
      if [ "$3" = "$NODE" ]; then
        FOUND=1
        NODENAME="$3"
        break
      else
        continue
      fi
    done
    if [ $FOUND -lt 1 ]; then
      usage
      rm $InsDir/.autolock
      exit 1
    fi
elif [ "$2" = "all" ]; then
    MODE="all"
else
    MODE="unknown"
fi

if [ "$COMMAND" = "keeprunning" -o "$COMMAND" = "keep-running" ]; then
    # Compare the number of nodes in the ES cluster and the number of node in the SPO cluster
    now=$( date )
    echo "========= Checking cluster at time $now ============" >> $LOG
    BOOTSTRAP_STATUS="$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/" | grep "status" | grep -o '[0-9]\+' )"
    if [ "$BOOTSTRAP_STATUS" != "200" ]; then
      echo "Server $BOOTSTRAP_SERVER for bootstraping is not good, we exit here"
      now=$( date )
      echo "Server $BOOTSTRAP_SERVER for bootstraping is not good, we checking all node status" >> $LOG
      for SERVER in $( cat $SERVERLIST ); do
        now=$( date )
        CODE_STATUS="$( curl -s -XGET "http://${SERVER}.$DOMAIN:$PORT/" | grep "status" | grep -o '[0-9]\+' )"
        if [ "$CODE_STATUS" = "" ]; then CODE_STATUS="NO_CODE";fi
        echo "$now: Server $SERVER has code status of $CODE_STATUS" >> $LOG
      done
      rm $InsDir/.autolock
      exit 1
    else
      TOTAL_NODES="$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.${DOMAIN}:${PORT}/_cluster/health?pretty" | grep "number_of_nodes" | grep -o '[0-9]\+' )"
      echo "Total ES nodes in the cluster: $TOTAL_NODES"
      echo "Total nodes in the SPO cluster: $SPO_NODES"
      if [ "$TOTAL_NODES" != "$SPO_NODES" ]; then
        # not equal mean some node are down, we must force start those nodes
	COMMAND="start"
	MODE="force"
        echo "There are nodes down, we will check each node" 1>&2
      else
	# every things run well, no need to do anything
	echo "All node are fine!"
        now=$( date )
        echo "$now: All nodes are fine" >> $LOG
        CLUSTER_STATUS=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "green" )
        if [ ! $CLUSTER_STATUS -eq 1 ]; then
          echo "Cluster status is not green"
        fi
        rm $InsDir/.autolock
	exit 0
      fi
   fi
fi

if [ "$COMMAND" = "start" ]; then
    if [ "$MODE" = "force" ]; then
        for SERVER in $( cat $SERVERLIST ); do
            IGNODE_FOUND=0
            for IGNORESVR in $( cat $IGNORELIST ); do
              if [ "$SERVER" = "$IGNORESVR" ]; then
                IGNODE_FOUND=1
              fi
            done
            if [ "$IGNODE_FOUND" = "1" ]; then
              now=$( date )
              echo "$now: Ignore $SERVER" >> $LOG
              echo "Ignore $SERVER in force start process"
              continue
            fi
            echo "Checking server $SERVER"
            NUM_PROC=$( ssh -i $KEY $USERNAME@$SERVER "pgrep -u elasticsearch" | grep -c '' )
            if [ $NUM_PROC -gt 1 ]; then #Multiple proceses, kill of them but keep cluster green
                echo "There are $NUM_PROC elasticsearch processes running:"
                now=$( date )
                echo "$now: There are $NUM_PROC elasticsearch processes running" >> $LOG
                # Handle them
                LIST_PROC=$( ssh -i $KEY $USERNAME@$SERVER "pgrep -u elasticsearch" )
                echo "$LIST_PROC"
                for i in $LIST_PROC; do #Kill and wait for cluster green again
                   echo "Kill process $i"
                   ssh -tt -i $KEY ${USERNAME}@${SERVER} "sudo kill -9 $i"
                   CLUSTER_STATUS_GREEN=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "green" )
                   while [ "$CLUSTER_STATUS_GREEN" != "1" ]; do # TODO: what if cluster forever yellow or red
                       CLUSTER_STATUS_RED=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "red" )
                       if [ "$CLUSTER_STATUS_RED" = "1" ]; then
                           echo "Cluster is in RED state, exit for safety"
                           rm $InsDir/.autolock
                           exit 1
                       else
                           echo "Cluster status is in YELLOW state, wait 20s [GREEN = $CLUSTER_STATUS_GREEN]"
                           sleep 20
                       fi
                       CLUSTER_STATUS_GREEN=$( curl -s -XGET "http://${BOOTSTRAP_SERVER}.$DOMAIN:$PORT/_cluster/health" | grep -c "green" )
                   done
                done
            else # if NUM_PROC = 0 or 1, check process status
                PROCESS_STATUS=$( ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch status" | grep -c "is running..." )
                if [ $PROCESS_STATUS -ne 1 ]; then
                  while [ $PROCESS_STATUS -ne 1 ]; do # Case of zombie process
                    echo "ElasticSearch process on $SERVER is not running, forcing $SERVER to restart... [STATUS = $PROCESS_STATUS]"
                    now=$( date )
                    PROCESS_STATUS_MALFUNC=$( ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch status" | grep -c 'dead but pid file exists' )
                    PROCESS_EXIST=$( ssh -i $KEY $USERNAME@$SERVER "pgrep -u elasticsearch" | grep -c '' )
                    if [ $PROCESS_STATUS_MALFUNC -eq 1 -a "$PROCESS_EXIST" != "" ]; then
                        NODE_STATUS="$( curl -s -XGET "http://$SERVER.$DOMAIN:$PORT/" | grep 'status' | grep -o '[0-9]\+' )"
                        if [ "$NODE_STATUS" != "200" ]; then
                          echo "Node status is: $NODE_STATUS"
                          ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch force-reload"
                          echo "$now: ElasticSearch process on $SERVER is not running, force-reload $SERVER" >> $LOG
                        else
                          break # Igore this node if es node are in cluster
                        fi
                    else
                        ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch restart"
                        echo "$now: ElasticSearch process on $SERVER is not running, restart $SERVER" >> $LOG
                    fi
                    sleep 20
                    PROCESS_STATUS=$( ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch status" | grep -c "is running..." )
                    NODE_STATUS="$( curl -s -XGET "http://$SERVER.$DOMAIN:$PORT/" | grep "status" | grep -o '[0-9]\+' )"
                    while [ "$NODE_STATUS" != "200" -a "$PROCESS_STATUS" = "1" ]; do
                       echo "Waiting 20s for $SERVER joining the cluster"
                       sleep 20
                       NODE_STATUS="$( curl -s -XGET "http://$SERVER.$DOMAIN:$PORT/" | grep "status" | grep -o '[0-9]\+' )"
                       if [ "$NODE_STATUS" = "503" ]; then
                         break
                       fi
                    done
                  done
                else
                   echo "Process runs fine, let check elasticsearch node status"
                   NODE_STATUS="$( curl -s -XGET "http://$SERVER.$DOMAIN:$PORT/" | grep "status" | grep -o '[0-9]\+' )"
                   if [ "$NODE_STATUS" = "200" ]; then
                      echo "ES node $SERVER is fine"
		   else
                      echo "ES process is fine but ES node $SERVER need to be restarted [ NODE_STATUS = $NODE_STATUS ]"
		      echo "Restarting $SERVER..."
                      now=$( date )
                      echo "$now: ES process is fine but ES node $SERVER need to be restarted" >> $LOG
                      ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch restart"
                   fi					
                fi
             fi
        done
    elif [ "$MODE" = "node" ]; then
        SERVER="$NODENAME"
        echo "Starting ES node $SERVER"
        ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch start"
    elif [ "$MODE" = "all" ]; then
        echo "Start ElasticSearch cluster"
        sh $InsDir/SPOSendCommand.sh $USERNAME $KEY $SERVERLIST "sudo service elasticsearch start"
    else
        echo "Syntax is not correct"
        usage
        rm $InsDir/.autolock
        exit 1	    
    fi
elif [ "$COMMAND" = "stop" ]; then
    if [ "$MODE" = "node" ]; then
        SERVER="$NODENAME"
        echo "Stopping ES node $SERVER"
        ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch stop"	
    elif [ "$MODE" = "all" ]; then
        echo "Stop ElasticSearch cluster"
        sh $InsDir/SPOSendCommand.sh $USERNAME $KEY $SERVERLIST "sudo service elasticsearch stop"
    else
        echo "Syntax is not correct"
        usage
        rm $InsDir/.autolock
        exit 1
    fi
elif [ "$COMMAND" = "status" ]; then
    if [ "$MODE" = "node" ]; then
        SERVER="$NODENAME"
        echo "Get status of node $SERVER"
        ssh -tt -i $KEY $USERNAME@$SERVER "sudo service elasticsearch status"	
    elif [ "$MODE" = "all" ]; then
        echo "Get status of the ElasticSearch cluster"
        sh $InsDir/SPOSendCommand.sh $USERNAME $KEY $SERVERLIST "sudo service elasticsearch status"
    else
        echo "Syntax is not correct"
        usage
        rm $InsDir/.autolock
        exit 1
    fi
else
    echo "Syntax is not correct"
    rm $InsDir/.autolock
    usage
    exit 1
fi

rm $InsDir/.autolock
exit 0
