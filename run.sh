#!/bin/bash

set -x

function setPostgresPassword() {
    sudo -E -u postgres psql -c "ALTER USER renderer PASSWORD '${RENDERER_PASSWORD}'" -h $PGHOST -p $PGPORT
}

function setPasswordInStylesheet() {
  cd /home/renderer/src/openstreetmap-carto/
  envsubst < project.mml > project-filled.mml
  carto project-filled.mml > mapnik.xml
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Set up the database and import /data.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    exit 1
fi

if [ "$1" = "import" ]; then
    # Initialize PostgreSQL
    setPasswordInStylesheet
    adduser --disabled-password --gecos "" postgres
    sudo -E -u postgres createuser renderer -h $PGHOST -p $PGPORT
    sudo -E -u postgres createdb -E UTF8 -O renderer gis -h $PGHOST -p $PGPORT
    sudo -E -u postgres psql -d gis -c "CREATE EXTENSION postgis;" -h $PGHOST -p $PGPORT
    sudo -E -u postgres psql -d gis -c "CREATE EXTENSION hstore;" -h $PGHOST -p $PGPORT
    sudo -E -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;" -h $PGHOST -p $PGPORT
    sudo -E -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;" -h $PGHOST -p $PGPORT
    setPostgresPassword

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data.osm.pbf ] && [ -z "$DOWNLOAD_PBF" ]; then
        echo "WARNING: No import file at /data.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "$DOWNLOAD_PBF" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget -nv "$DOWNLOAD_PBF" -O /data.osm.pbf
        if [ -n "$DOWNLOAD_POLY" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget -nv "$DOWNLOAD_POLY" -O /data.poly
        fi
    fi

    if [ "$UPDATES" = "enabled" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        osmium fileinfo /data.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
        osmium fileinfo /data.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
        REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -u renderer openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data.poly ]; then
        sudo -u renderer cp /data.poly /var/lib/mod_tile/data.poly
    fi

    # Import data
    PGPASSWORD=${RENDERER_PASSWORD} bash -c 'sudo -E -u renderer osm2pgsql -d gis --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf ${OSM2PGSQL_EXTRA_ARGS} -H $PGHOST -P $PGPORT'

    # Create indexes
    sudo -E -u postgres psql -d gis -f indexes.sql -h $PGHOST -p $PGPORT

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

    # Initialize PostgreSQL and Apache
    setPasswordInStylesheet
    service apache2 restart

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "$UPDATES" = "enabled" ] || [ "$UPDATES" = "1" ]; then
      /etc/init.d/cron start
    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /usr/local/etc/renderd.conf &
    child=$!
    wait "$child"

    exit 0
fi

echo "invalid command"
exit 1
