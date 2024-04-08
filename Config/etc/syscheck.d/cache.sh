#!/usr/bin/bash

rm "/etc/.updated" 2> /dev/null
rm "/etc/.pwd.lock" 2> /dev/null

linkcheck "/etc/ld.so.cache" "/var/cache/ld.so.cache"
linkcheck "/etc/pacman.d/gnupg" "/var/db/pacman/gnupg"
linkcheck "/etc/pacman.d/mirrorlist" "/var/cache/pacman/mirrorlist"

chmod 0644 "/var/cache/ld.so.cache"
chown root:root "/var/cache/ld.so.cache"

chmod -R 0750 "/var/cache/pacman/pkg"
chmod 0640 /var/cache/pacman/pkg/*
chown -R root:root "/var/cache/pacman/pkg"

chmod 0755 "/var/lib/pacman/sync"
chmod 0644 /var/lib/pacman/sync/*
chown -R root:root "/var/lib/pacman/sync"

chmod -R 0755 "/var/lib/pacman/local"
chown -R root:root "/var/lib/pacman/local"
find "/var/lib/pacman" -type f -exec chmod 0644 {} \;

chmod 0700 "/var/cache/ldconfig"
chown -R root:root "/var/cache/ldconfig"
