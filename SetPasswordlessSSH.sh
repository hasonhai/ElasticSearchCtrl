#!/bin/bash

# Usage: ./SetPasswordlessSSH.sh <hostname> <username> <key>

filename="id_rsa"
path="$HOME/.ssh"

if [ $1 ]
then
    hostname=$1
    if [ $2 ]
    then
        username=$2
    else
	# Use current user
        username="$USER"
    fi
else
    # Read the host and username to store public key (the host/username accepting passwordless ssh from this computer)
    echo "What host you want to grant passwordless SSH from this computer?"
    read hostname
    echo "What is your username on $hostname? ($USER?)"
    read username

    if [ ! $username ]
    then
        username="$USER"
    fi
fi

# Generate rsa files
if [ -f $path/$filename ]
then
    echo "RSA key exists on $path/$filename, using existing file"
else
    ssh-keygen -t rsa -f "$path/$filename"
    echo RSA key pair generated
fi

# Log into the remote host to setup private key
echo "We need to log into $hostname as $username to set up your public key (hopefully last time you'll use password from this computer)" 
cat "$path/$filename.pub" | ssh "$hostname" -l "$username" '[ -d .ssh ] || mkdir .ssh; cat >> .ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
status=$?

if [ $status -eq 0 ]
then
    echo "Set up complete, try to ssh to $hostname now"
    if [ $3 ]
    then
        KEY="$3"
        cp $path/$filename $KEY
        echo "Your private key is $KEY"
    else
        echo "Your private key is $path/$filename"
    fi
    exit 0
else
    echo "An error has occurred, set up fail!"
    exit 255
fi
