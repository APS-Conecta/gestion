#!/bin/bash

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

while true; do
    if [ -f "/mnt/docker-aio-config/data/daily_backup_time" ]; then
        set -x
        BACKUP_TIME="$(head -1 "/mnt/docker-aio-config/data/daily_backup_time")"
        export BACKUP_TIME
        export DAILY_BACKUP=1
        export START_CONTAINERS=1
        if [ "$(sed -n '2p' "/mnt/docker-aio-config/data/daily_backup_time")" != 'successNotificationsAreNotEnabled' ]; then
            export SEND_SUCCESS_NOTIFICATIONS=1
        else
            export SEND_SUCCESS_NOTIFICATIONS=0
        fi
        if [ "$AIO_LOG_LEVEL" != 'debug' ]; then
            set +x
        fi
        if [ -f "/mnt/docker-aio-config/data/daily_backup_running" ]; then
            export LOCK_FILE_PRESENT=1
        else
            export LOCK_FILE_PRESENT=0
        fi
    else
        export BACKUP_TIME="04:00"
        export DAILY_BACKUP=0
        export LOCK_FILE_PRESENT=0
    fi

    # Resume an interrupted backup immediately; otherwise wait for its scheduled time.
    if [ "$LOCK_FILE_PRESENT" = 0 ]; then
        while [ "$(date +%H:%M)" != "$BACKUP_TIME" ]; do 
            sleep 30
        done
    fi

    if [ "$DAILY_BACKUP" = 1 ]; then
        bash /daily-backup.sh
    fi

    # Make sure to delete the lock file always
    rm -f "/mnt/docker-aio-config/data/daily_backup_running"

    # Remove sessions older than 24h
    find "/mnt/docker-aio-config/session/" -mindepth 1 -mmin +1440 -delete

    # Remove aps-conecta-domaincheck container
    if su-exec www-data docker ps --format "{{.Names}}" --filter "status=exited" | grep -q "^aps-conecta-domaincheck$"; then
        su-exec www-data docker container remove aps-conecta-domaincheck
    fi

    # Check for available free space
    su-exec www-data php /var/www/docker-aio/php/src/Cron/CheckFreeDiskSpace.php

    # Remove mastercontainer from default bridge network
    if su-exec www-data docker inspect nextcloud-aio-mastercontainer  --format "{{.NetworkSettings.Networks}}" | grep -q "bridge"; then
        su-exec www-data docker network disconnect bridge nextcloud-aio-mastercontainer
    fi

    # Wait 60s so that the whole loop will not be executed again
    sleep 60
done
