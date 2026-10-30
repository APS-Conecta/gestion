#!/bin/bash

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

health="$(curl -fsS http://127.0.0.1/healthcheck)" || exit 1
[ "$health" = true ] || exit 1
