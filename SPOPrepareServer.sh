#!/bin/bash

# This script is used to configure a server before deploy Ambari
# The server should have CentOS 6.5 already
# You have to modify the config of this script to fit your cluster
# Usage:
#	./SPOPrepareServer.sh <server-ip> <hostname> [mode]

# TODO: Code to display usage manual and check args

# Import functions from other source
source customfunc.sh

# Set config file name
CONFIGFILE="test.cfg"

# Default parameters
DEFAULT_MODE="agent"
KEY="conf/SPOkey.pem"		# private key for SSH-passwordless accessing, comment out if you don't have
HOSTSFILE="conf/hosts"		# /etc/hosts config, for cluster with no DNS server
NTPSVRS="conf/NTPservers.lst" 	# List of NTP servers
SVRSLST="conf/servers.lst"	# List of servers currently in the cluster
USERNAME="root"			# Username for the host need to prepare
DOMAIN="hadoop.spo"		# Domain name of the cluster
AMBARI_REPO_URL="http://public-repo-1.hortonworks.com/ambari/centos6/1.x/updates/1.6.1/ambari.repo"
# For local repository only, some cluster cannot access Hortonworks repository
HDP_REPO="http://public-repo-1.hortonworks.com/HDP/centos6/2.x/GA/2.1-latest/HDP-2.1-latest-centos6-rpm.tar.gz"
HDP_UTIL_REPO="http://public-repo-1.hortonworks.com/HDP-UTILS-1.1.0.17/repos/centos6/HDP-UTILS-1.1.0.17-centos6.tar.gz"
HDP_TAR=$(basename $HDP_REPO)
HDP_UTIL_TAR=$(basename $HDP_UTIL_REPO)

# If there is config file for the cluster, use the config file to overwrite the default parameter
if [ -f "$CONFIGFILE" ]
then
    source $CONFIGFILE
fi

# Parsing arguments
HOST_IP=$1	# IP of the host
HOST=$2		# hostname in short, e.g, svr1 for server svr1.hadoop.spo
MODE=$3		# role of the host, agent or master

# Check Mode, user can ignore mode at input
if [ "$MODE" != "master" ]
then
    echo "Set mode to AGENT mode"
    MODE=$DEFAULT_MODE
fi

# Check Host IP
if [ -z "$HOST_IP" ]; then
    echo -n "Please enter host IP: "
    read HOST_IP < /dev/tty
fi

if valid_ip $HOST_IP; then
    # Check Host Name
    if [ -z "$HOST" ]; then
        echo -n "Please enter hostname in short: "
        read HOST < /dev/tty
    fi

    if valid_hostname "$HOST.$DOMAIN"; then
        echo "Hostname and IP look good"
    else
        echo "Hostname is not correct. Exiting."
        exit 1
    fi
else
    echo "IP is not correct. Exiting."
    exit 1
fi

#TODO: If hostname and ip from arguments are similar to remote host, no need to change hostname

# Detect where script is run
MY_IP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)
if [ "$MY_IP" = "$HOST_IP" ]
then
    # Running script on localhost
    SSH_TO_HOST=""
else
    # Running script remotely
    if [ ! $KEY ]
    then
        echo "You have not specified the private key to access your host!"
        echo "Do you want to setup SSH-passwordless for your host (y/N)?"
        read answer < /dev/tty
        if [ "$answer" = "y" -o "$answer" = "Y" -o "$answer" = "yes" -o "$answer" = "Yes" ]
        then
            KEY="privatekey.pem" 
            sh SetPasswordlessSSH.sh $HOST_IP $USERNAME $KEY
        else
            echo "It's mandatory to access host passwordlessly with SSH."
            echo "Set the key if you have one."
            exit 1
        fi
     else
        # There is private key set, but file is not existed
        echo "Your given private key path is: $KEY"
        if [ -f $KEY ]
        then
            echo "Using key: $KEY"
            SSH_TO_HOST="ssh -i $KEY $USERNAME@$HOST_IP"
        else
            echo "Found no private key!"
            exit 1
        fi
     fi
fi

# Check for hosts file, if not exist, create one
if [ -f "$HOSTSFILE" ]
then
    echo -e "127.0.0.1\tlocalhost\tlocalhost.localdomain" >> $HOSTSFILE
    echo -e "::1\tlocalhost\tlocalhost.localdomain" >> $HOSTSFILE
    # Add NTP server address to hosts file if needed
    if [ -f "$NTPSVRS" ]
    then
		#TODO: Gererate the NTP config file here
		NTPCONF="ntp.conf"
        cat $NTPSVRS >> $HOSTSFILE
    fi
fi

# Update the remote server
$SSH_TO_HOST "yum update -y"

echo "Disable iptables for Ambari on the host"
$SSH_TO_HOST "chkconfig iptables off" # Prevent iptables start after server reboot
$SSH_TO_HOST "/etc/init.d/iptables start; /etc/init.d/iptables stop" # Insert iptables modules then turn-off filewall
$SSH_TO_HOST "/etc/init.d/iptables status" #Just to make sure

echo "Disable SELinux on the host"
$SSH_TO_HOST "setenforce 0"

echo "Set umask value on the host"
$SSH_TO_HOST "umask 022"

echo "Edit hostname for the host"
HOSTNAME="$HOST.$DOMAIN"
scp -i $KEY changehostname.sh $USERNAME@$HOST_IP:~/changehostname.sh
$SSH_TO_HOST "chmod a+x changehostname.sh; sh changehostname.sh $HOSTNAME; rm -f changehostname.sh"

echo "Setup NTP server on host"
$SSH_TO_HOST "yum install -y ntp ntpdate ntp-doc"
scp -i $KEY $NTPCONF $USERNAME@$HOST_IP:/etc/ntp.conf
$SSH_TO_HOST "chkconfig ntpd on; ntpdate pool.ntp.org; /etc/init.d/ntpd start"

echo "Disable ipv6 (optional, in case ambari-server listen on port with IPv6 address)"
$SSH_TO_HOST "sysctl -w net.ipv6.conf.all.disable_ipv6=1; sysctl -w net.ipv6.conf.default.disable_ipv6=1"

echo "Get the Ambari-repo"
if [ -f ambari.repo ]
then
	wget $AMBARI_REPO_URL
	scp -i $KEY ambari.repo $USERNAME@$HOST_IP:/etc/yum.repos.d/
	rm -f ambari.repo
fi

# If mode=master
if [ "$MODE" = "master" ]
then
    # Install Apache Webserver:
    $SSH_TO_HOST "yum install httpd -y; /etc/init.d/httpd start"
    # Download the repo for local use:
    $SSH_TO_HOST "wget $HDP_REPO"
    $SSH_TO_HOST "wget $HDP_UTIL_REPO"
    # Extract to /var/www/html
    $SSH_TO_HOST "yum install -y yum-utils createrepo"
    $SSH_TO_HOST "mkdir -p /var/www/html"
    $SSH_TO_HOST "PWD=$(pwd);cd /var/www/html; tar -zxvf $PWD/$HDP_TAR; tar -zxvf $PWD/$HDP_UTIL_TAR"
    #TODO: Set address for the repository
    HDP_ADDRESS="Somewhere at http://$HOST_IP/"
    HDP_UTIL_ADDRESS="Somewhere at http://$HOST_IP/"
    $SSH_TO_HOST "yum install -y ambari-server"
    # We need user interaction here
    $SSH_TO_HOST "ambari-server setup"
    # After user finished setup, we can start install Hadoop from the Web now
    $SSH_TO_HOST "ambari-server start"
else # "agent" mode
    #TODO: No need to install ambari-agent here
    #      We can install it at the Web UI of Ambari Server
fi

echo "FINISH PREPARING THE SERVER AS $MODE MODE"
if [ "$MODE" = "master" ]
then
    #TODO: Display the next instruction here
    echo "Please access Ambari Web to install Hadoop at: http://$HOST_IP:8080/"
    echo "If you are going to run Hadoop on Openstack, please remember to open ports for the services to work"
    echo "Your HDP repository is at: $HDP_ADDRESS"
    echo "Your HDP UTIL repository is at: $HDP_UTIL_ADDRESS"
else
    #TODO: Display the next instruction here
    echo "Please access Ambari Web to add $HOST to your Hadoop cluster"
fi

# Append the remote host IP to the hosts file
echo -e "$HOST_IP\t$HOST.$DOMAIN\t$HOST"

# Append the hostname to the control list
echo $HOST >> $SVRSLST

# Distribute the host file to all nodes in the cluster
sh SPODistributeFile.sh $KEY $SVRSLST $HOSTSFILE /etc/hosts
