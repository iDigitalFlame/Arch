#!/usr/bin/bash

source "/etc/sysconfig.conf" 2> /dev/null
if [ -z "$SYSCONFIG" ]; then
    echo "Could not find the System Configuration directory!"
    exit 1
fi
if ! [ -d "$SYSCONFIG" ]; then
    printf "System Configuration directory \"%s\" does not exist!\n" "$SYSCONFIG"
    exit 1
fi

if [ -d "${SYSCONFIG}/.git" ]; then
    chmod 0750 "$SYSCONFIG"/.git/hooks/*
    bash -c "cd ${SYSCONFIG}; git status" 2> /dev/null 1> /dev/null
fi
