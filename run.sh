#!/bin/bash

set -x

function createPostgresConfig() {
  cp /etc/postgresql/12/main/postgresql.custom.conf.tmpl /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/12/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Import /data.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    PGPASS:  PostgreSQL Password"
    echo "    PGUSER:  PostgreSQL Username"
    echo "    PGHOST:  PostgreSQL Host"
    echo "    PGPORT:  PostgreSQL PORT"
    echo "    PGDB:    PostgreSQL Database"
    exit 1
fi

if [ "$1" = "import" ]; then
  

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data.osm.pbf ] && [ -z "$DOWNLOAD_PBF" ]; then
        echo "WARNING: No import file at /data.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "$DOWNLOAD_PBF" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget "$WGET_ARGS" "$DOWNLOAD_PBF" -O /data.osm.pbf
        if [ -n "$DOWNLOAD_POLY" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget "$WGET_ARGS" "$DOWNLOAD_POLY" -O /data.poly
        fi
    fi

    if [ "$UPDATES" = "enabled" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        osmium fileinfo /data.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
        osmium fileinfo /data.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
        REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data.poly ]; then
        sudo -E -u renderer cp /data.poly /var/lib/mod_tile/data.poly
    fi

    # Import data
    sudo -E -u renderer osm2pgsql --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf ${OSM2PGSQL_EXTRA_ARGS}

    # Create indexes
    sudo -E -u renderer psql  -f /home/renderer/src/openstreetmap-carto/indexes.sql
    #Import external data
    sudo chown -R renderer: /home/renderer/src
    #sudo -u renderer python3 /home/renderer/src/openstreetmap-carto/scripts/get-external-data.py -c /home/renderer/src/openstreetmap-carto/external-data.yml -D /home/renderer/src/openstreetmap-carto/data -d osmhosting -H 10.0.1.6 -p 5432 -U postgres -w postgres
    sudo -E -u renderer python3 /home/renderer/src/openstreetmap-carto/scripts/get-external-data.py -c /home/renderer/src/openstreetmap-carto/external-data.yml -D /home/renderer/src/openstreetmap-carto/data -d $PGDATABASE -U $PGUSER -w $PGPASSWORD -H $PGHOST -p $PGPORT 

    # Register that data has changed for mod_tile caching purposes
    touch /var/lib/mod_tile/planet-import-complete

    exit 0
fi

if [ "$1" = "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*


    # Configure Apache CORS
    if [ "$ALLOW_CORS" == "enabled" ] || [ "$ALLOW_CORS" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    cp /home/renderer/src/openstreetmap-carto/mapnik.xml /home/renderer/src/openstreetmap-carto/mapnik_cpy.xml
    envsubst '$PGPASSWORD $PGUSER $PGHOST $PGPORT $PGDATABASE' </home/renderer/src/openstreetmap-carto/mapnik_cpy.xml >/home/renderer/src/openstreetmap-carto/mapnik.xml

    service apache2 restart    

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "$UPDATES" = "enabled" ]; then
        chown renderer /home/renderer/project_env.sh
        chmod +x /home/renderer/project_env.sh
        printenv | sed 's/^\(.*\)$/export \1/g' | grep -E "^export PG" >/home/renderer/project_env.sh
        /etc/init.d/cron start
    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -E -u renderer renderd -f -c /usr/local/etc/renderd.conf &
    child=$!
    wait "$child"

fi

if [ "$1" = "debug" ]; then
    cp /home/renderer/src/openstreetmap-carto/mapnik.xml /home/renderer/src/openstreetmap-carto/mapnik_cpy.xml
    envsubst '$PGPASSWORD $PGUSER $PGHOST $PGPORT $PGDATABASE' </home/renderer/src/openstreetmap-carto/mapnik_cpy.xml >/home/renderer/src/openstreetmap-carto/mapnik.xml

    exit 0
fi

echo "invalid command"
exit 1
