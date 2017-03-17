#!/bin/sh

##
# Run database operations
#
# The database affected depends on the value of the $RAILS_ENV
# environment variable.  This defaults to 'development' but can be set
# to 'production'
#

# Command prefix that runs the command as the web user
asweb="setuser www-data"

die () {
    msg=$1
    echo "FATAL ERROR: " msg > 2
    exit
}

_getdbname () {
    if [ -z "$RAILS_ENV" ] || [ "$RAILS_ENV" = 'development' ]
    then
        dbname=openstreetmap    # development
    else
        dbname=osm              # production
    fi

    echo $dbname
}

_startservice () {
    sv start $1 || die "Could not start $1"
}

startdb () {
    _startservice postgresql
}

initdb () {
    echo "Initialising postgresql"
    if [ -d /var/lib/postgresql/9.5/main ] && [ $( ls -A /var/lib/postgresql/9.5/main | wc -c ) -ge 0 ]
    then
        die "Initialisation failed: the directory is not empty: /var/lib/postgresql/9.5/main"
    fi

    mkdir -p /var/lib/postgresql/9.5/main && chown -R postgres /var/lib/postgresql/
    sudo -u postgres -i /usr/lib/postgresql/9.5/bin/initdb --pgdata /var/lib/postgresql/9.5/main
    ln -s /etc/ssl/certs/ssl-cert-snakeoil.pem /var/lib/postgresql/9.5/main/server.crt
    ln -s /etc/ssl/private/ssl-cert-snakeoil.key /var/lib/postgresql/9.5/main/server.key
}

createuser () {
    USER=www-data
    echo "Creating user $USER"
    setuser postgres createuser -s $USER
}

createdb () {
    dbname=$( _getdbname )
    echo "Creating database $dbname"
    cd /var/www
    $asweb bundle exec rake db:create
}

createdbfuncs () {
    dbname=$( _getdbname )
    echo "Creating functions in database $dbname"
    cd /var/www

    # Install the Postgresql Btree-gist extension
    $asweb psql -d $dbname -c "CREATE EXTENSION btree_gist"

    # Install the Postgresql functions
    $asweb psql -d $dbname -c "CREATE FUNCTION maptile_for_point(int8, int8, int4) RETURNS int4 AS '`pwd`/db/functions/libpgosm', 'maptile_for_point' LANGUAGE C STRICT"
    $asweb psql -d $dbname -c "CREATE FUNCTION tile_for_point(int4, int4) RETURNS int8 AS '`pwd`/db/functions/libpgosm', 'tile_for_point' LANGUAGE C STRICT"
    $asweb psql -d $dbname -c "CREATE FUNCTION xid_to_int4(xid) RETURNS int4 AS '`pwd`/db/functions/libpgosm', 'xid_to_int4' LANGUAGE C STRICT"
}

migrate () {
    echo "Migrating database"
    cd /var/www
    $asweb bundle exec rake db:migrate
}

import () {
    dbname=$( _getdbname )

    # Find the most recent import.pbf or import.osm
    import=$( ls -1t /data/import.pbf /data/import.osm 2>/dev/null | head -1 )
    test -n "${import}" || \
        die "No import file present: expected /data/import.osm or /data/import.pbf"

    # Decide whether we are reading an xml or pbf file
    if echo $import | grep '.osm$'
    then
        read_cmd=xml
    else
        read_cmd=pbf
    fi

    echo "Importing ${import} into ${dbname}"
    $asweb osmosis --read-$read_cmd file=$import --write-apidb database=$dbname user="www-data" validateSchemaVersion=no
}

dropdb () {
    echo "Dropping database"
    cd /var/www
    $asweb bundle exec rake db:drop
}

cli () {
    echo "Running bash"
    cd /var/www
    exec bash
}

startcgimap () {
    _startservice cgimap
}

startdevserver () {
    _startservice devserver
}

startservices () {
    if [ "$RAILS_ENV" = 'development' ]
    then
        startdevserver
        a2ensite development
    else
        startcgimap
        a2ensite cgimap production
    fi

    _startservice apache2
}

help () {
    cat /usr/local/share/doc/run/help.txt
}

_wait () {
    WAIT=$1
    NOW=`date +%s`
    BOOT_TIME=`stat -c %X /etc/container_environment.sh`
    UPTIME=`expr $NOW - $BOOT_TIME`
    DELTA=`expr 5 - $UPTIME`
    if [ $DELTA -gt 0 ]
    then
	sleep $DELTA
    fi
}

# Unless there is a terminal attached wait until 5 seconds after boot
# when runit will have started supervising the services.
if ! tty --silent
then
    _wait 5
fi

# Execute the specified command sequence
for arg 
do
    $arg;
done

# Unless there is a terminal attached don't exit, otherwise docker
# will also exit
if ! tty --silent
then
    # Wait forever (see
    # http://unix.stackexchange.com/questions/42901/how-to-do-nothing-forever-in-an-elegant-way).
    tail -f /dev/null
fi
