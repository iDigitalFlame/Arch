#!/usr/bin/bash

linkcheck "/etc/syslesskey" "/etc/sysless"
linkcheck "/usr/local/etc/syslesskey" "/etc/sysless"

chmod 0444 "/etc/sysless"
chmod 0444 "/etc/syslesskey"
chmod 0444 "/usr/local/etc/syslesskey"
