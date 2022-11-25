#!/usr/bin/bash

status_repo() {
    source "/etc/sysconfig.conf" 2> /dev/null
    if [ $? -ne 0 ]; then
        return 0
    fi
    if [ -z "$SYSCONFIG" ]; then
        return 0
    fi
    if ! [ -d "$SYSCONFIG" ]; then
        return 0
    fi
    SYSCONFIG=${SYSCONFIG%/}
    if ! [ -d "${SYSCONFIG}/.git" ]; then
        return 0
    fi
    if ! [[ -z $(bash -c "cd ${SYSCONFIG}; git status | grep -iE 'modified|deleted|Untracked'") ]]; then
        printf '# Config:\tSync needed, use "syspush"\n'
    else
        printf "# Config:\tUp-to-Date\n"
    fi
}
status_storage() {
    printf "# Storage:\n"
    df -h | grep -v "tmpfs" | grep -E '/dev/|/opt/|/mnt/' | sort -r | awk '{print ""$1" "$5" ("$3"/"$2")"}' | column -t | awk '{print "#     "$0}'
}
status_network() {
    printf "# Interface Addresses:\n"
    for i in $(ip addr |grep 'inet' | grep -vE '::1|127.0.0.1|link' | awk '{print $2}' | awk -F'/' '{print $1}'); do
        printf "#     $i\n"
    done
}
status_services() {
    nl=$(netstat -panut 2>/dev/null | grep LISTEN | wc -l)
    ne=$(netstat -panut 2>/dev/null | grep ESTABLISHED | wc -l)
    printf "# Network:\t$ne Established, $nl Listening\n"
    st=$(systemctl --all --no-legend --no-pager | grep ".timer" | wc -l)
    sf=$(systemctl --state=failed --no-legend --no-pager | grep ".service" | wc -l)
    sa=$(systemctl --state=active --no-legend --no-pager | grep ".service" | grep "running" | wc -l)
    printf "# Services:\t$sa Running, $sf Failed, $st Timers\n"
}

if [[ $- != *i* ]] || [ ! -z "$SSH_CLIENT" ]; then
    printf "##############################################################\n"
    status_storage
    status_network
    printf "# Uptime:\t$(uptime --pretty | sed 's/up //g')\n"
    printf "# Kernel:\t$(uname -r)\n"
    status_repo
    status_services
    printf "##############################################################\n"
fi
