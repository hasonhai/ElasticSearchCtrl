#!/bin/bash
#----------------------------------------------------
# a simple mysql database backup script.
# version 2, updated March 26, 2011.
# copyright 2011 alvin alexander, http://devdaily.com
#----------------------------------------------------
# This work is licensed under a Creative Commons 
# Attribution-ShareAlike 3.0 Unported License;
# see http://creativecommons.org/licenses/by-sa/3.0/ 
# for more information.
#----------------------------------------------------

# (1) set up all the variables
FILEPATH="/mnt/backup/ambaribackup"
FILE=$FILEPATH/ambarirca.pgsql.`date +"%Y%m%d"`
DBSERVER=svr01.spo
DATABASE=ambarirca
USER=mapred
export PGPASSWORD=mapred

# (2) in case you run this more than once a day, remove the previous version of the file
unalias rm     2> /dev/null
rm ${FILE}     2> /dev/null
rm ${FILE}.gz  2> /dev/null

# (3) do the postgresql database backup (pg_dump)

pg_dump --host=${DBSERVER} --user=${USER} ${DATABASE} > ${FILE}

# (4) gzip the mysql database dump file
gzip $FILE

# (5) show the user the result
echo "${FILE}.gz was created:"
ls -l ${FILE}.gz
