#!/bin/bash

set +x

REDISCLI_AUTH="$REDIS_HOST_PASSWORD" redis-cli PING || exit 1
