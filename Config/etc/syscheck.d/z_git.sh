#!/usr/bin/bash

source "/etc/sysconfig.conf" 2> /dev/null
if [ -n "$SYSCONFIG" ]; then
    if [ -d "$SYSCONFIG" ]; then
        if [ -d "${SYSCONFIG}/.git" ]; then
            chmod 0750 "$SYSCONFIG"/.git/hooks/*
            bash -c "cd ${SYSCONFIG}; git status -s" 2> /dev/null
        fi
    else
        printf 'Error: system configuration directory "%s" does not exist!\n' "$SYSCONFIG"
    fi
else
    echo "Error: system configuration directory not found!"
fi
