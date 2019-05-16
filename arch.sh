#!/usr/bin/bash

SETUP_EFI=1
SETUP_NET=()
SETUP_AUTO=0
SETUP_SSHKEY=""
SETUP_FS="btrfs"
SETUP_DRIVE="/dev/sda"
SETUP_HOSTNAME="archlinux"
SETUP_CONFIGURATION="/opt/sysconfig"
SETUP_DIRECTORY="/mnt$SETUP_CONFIGURATION"

_RESULT=""

log() {
    printf "[+] $1\n"
}

yes() {
    empty=0
    printf "[?] $1 ["
    if [[ $# -eq 2 && "$2" == "1" ]]; then
        empty=1
        printf "Y/n]? "
    else
        printf "y/N]? "
    fi
    read check
    if [[ $empty -eq 1 && -z "$check" ]]; then
        return 0
    fi
    if [[ "$check" == "Y" || "$check" == "y" ]]; then
        return 0
    fi
    return 1
}

ask() {
    printf "[?] $1? "
    read check
    if [[ ! -z "$check" ]]; then
        _RESULT="$check"
        if [ $# -eq 2 ]; then
        return 0
        fi
        return 0
    fi
    _RESULT=""
    if [ $# -eq 2 ]; then
        return 0
    fi
    return 1
}

bail() {
    printf "[!] An error occured! $1\n"
    printf "[!] Cannot continue, quitting!\n"
    exit 1
}

setup_nic() {
    if [ $# -ne 1 ]; then
        return 1
    fi
    name=$1
    if yes "($name) Automatic Setup" 1; then
        SETUP_NET+=("$name,,,,,")
        return 0
    fi
    iname=$name
    if ask "($iname) Rename this interface"; then
        iname="$_RESULT"
    fi
    if yes "($iname) Use DHCP for this interface" 1; then
        SETUP_NET+=("$name,$iname,,,,")
        return 0
    fi
    address=$(ip addr show dev $name | grep inet | grep brd | awk '{print $2}')
    gateway=$(route -n | grep $name | grep 0.0.0.0 | grep "UG" | awk '{print $2}')
    if ask "($iname) IPv4 Address [$address]"; then
        address="$_RESULT"
    fi
    if ask "($iname) IPv4 Gateway [$gateway]"; then
        gateway="$_RESULT"
    fi
    dns_servers=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | head -2)
    dns1=$(echo $dns_servers | awk '{print $1}')
    dns2=$(echo $dns_servers | awk '{print $2}')
    if ask "($iname) Primary DNS Server [$dns1]"; then
        dns1="$_RESULT"
    fi
    if ask "($iname) Secondary DNS Server [$dns2] (Optional)"; then
        dns2="$_RESULT"
    fi
    SETUP_NET+=("$name,$iname,$address,$gateway,$dns1,$dns2")
    return 0
}

setup_init() {
    ping -c 1 google.com &> /dev/null
    if [ $? -ne 0 ]; then
        bail "No internet connection! How did you get this script?"
    fi
    pacman -Syy
    pacman -S archlinux-keyring --noconfirm
    if [ $SETUP_AUTO -eq 1 ]; then
        return 0
    fi
    efibootmgr &> /dev/null
    if [ $? -eq 2 ]; then
        SETUP_EFI=0
    fi
    if ask "System Hostname: [$SETUP_HOSTNAME]"; then
        SETUP_HOSTNAME="$_RESULT"
    fi
    if ! yes "BTRFS as root Filesystem" 1; then
        sel=0
        while [ $sel -eq 0 ]; do
            if ask "Select Filesystem Type: [btrfs/ext4/xfs]"; then
                case $_RESULT in
                    "ext4")
                    SETUP_FS="ext4"
                    sel=1
                    ;;
                    "xfs")
                    SETUP_FS="xfs"
                    sel=1
                    ;;
                    "btrfs")
                    SETUP_FS="btrfs"
                    sel=1
                    ;;
                    *)
                    sel=0
                    ;;
                esac
            fi
        done
    fi
    for nic in $(ifconfig -a | grep flags | awk -F':' '{print $1}' | grep -v "lo"); do
        setup_nic "$nic"
    done
    if yes "Autodetect Disk" 1; then
        if [ -b "/dev/sda" ]; then
            SETUP_DRIVE="/dev/sda"
        elif [ -b "/dev/vda" ]; then
            SETUP_DRIVE="/dev/vda"
        elif [ -b "/dev/xda" ]; then
            SETUP_DRIVE="/dev/xda"
        fi
    else
        SETUP_DRIVE=""
    fi
    if [[ -z "$SETUP_DRIVE" ]] || ! [ -b "$SETUP_DRIVE" ]; then
        while [ -z "$SETUP_DRIVE"  ]; do
            lsblk 2> /dev/null
            if ask "Select a Disk to use"; then
                if [ -b $_RESULT ]; then
                    SETUP_DRIVE="$_RESULT"
                fi
            fi
        done
    fi
    if [ -z "$SETUP_DRIVE" ]; then
        bail "No drive selected!"
    fi
    return 0
}

setup_disk() {
    log "Creating partitions on \"${SETUP_DRIVE}\".."
    umount ${SETUP_DRIVE}* 2> /dev/null
    lvdisk=$(lvdisplay | grep "LV Path" | awk '{print $3}')
    if ! [ -z "$lvdisk" ]; then
        if ! yes "Remove current LVM partitions?" 1; then
            bail "Clear disks manually, then restart!"
        fi
        for lv in $lvdisk; do
            umount "$lv" 2> /dev/null
            lvremove --force "$lv"
        done
        for vg in $(vgdisplay | grep "VG Name" | awk '{print $3}'); do
            vgremove --force "$vg"
        done
        for pv in $(pvdisplay | grep "PV Name" | awk '{print $3}'); do
            pvremove --force "$pv"
        done
        partprobe
    fi
    if [ $SETUP_EFI -eq 1 ]; then
        log "Setting up EFI disk \"${SETUP_DRIVE}\".."
        printf "g\nn\n\n\n+200M\nt\n1\nn\n\n\n\nw" | fdisk $SETUP_DRIVE
        if [ $? -ne 0 ]; then
            bail "fdisk returned a non-zero error code!"
        fi
        partprobe
        mkfs.fat -F32 -nEFI "${SETUP_DRIVE}1"
        if [ $? -ne 0 ]; then
            bail "mkfs.fat returned a non-zero error code!"
        fi
    else
        log "Setting up MBR disk \"${SETUP_DRIVE}\".."
        printf "o\nn\n\n\n\n+200M\nt\nc\nn\n\n\n\n\nw" | fdisk $SETUP_DRIVE
        if [ $? -ne 0 ]; then
            bail "fdisk returned a non-zero error code!"
        fi
        partprobe
        mkfs.fat "${SETUP_DRIVE}1"
        if [ $? -ne 0 ]; then
            bail "mkfs.fat returned a non-zero error code!"
        fi
    fi
    log "Creating LVM partitions on \"${SETUP_DRIVE}2\".."
    pvcreate --force --yes "${SETUP_DRIVE}2"
    if [ $? -ne 0 ]; then
        bail "pvcreate returned a non-zero error code!"
    fi
    vgcreate --force --yes storage "${SETUP_DRIVE}2"
    if [ $? -ne 0 ]; then
        bail "vgcreate returned a non-zero error code!"
    fi
    lvcreate --yes -n root storage -l 100%FREE
    if [ $? -ne 0 ]; then
        bail "lvcreate returned a non-zero error code!"
    fi
    log "Formatting LVM partitions on \"${SETUP_DRIVE}2\".."
    case $SETUP_FS in
        "xfs")
        mkfs.xfs -f -L root /dev/mapper/storage-root
        ;;
        "btrfs")
        mkfs.btrfs -f -L root /dev/mapper/storage-root
        ;;
        "ext4")
        mkfs.ext4 -F -L root /dev/mapper/storage-root
        ;;
        *)
        mkfs.btrfs -f -L root /dev/mapper/storage-root
        ;;
    esac
    if [ $? -ne 0 ]; then
        bail "mkfs.${SETUP_FS} returned a non-zero error code!"
    fi
    log "Mounting LVM Partitions.."
    if [[ $SETUP_FS == "btrfs" ]]; then
        mount -t btrfs -o compress=lzo /dev/mapper/storage-root /mnt
        if [ $? -ne 0 ]; then
            bail "mount returned a non-zero error code!"
        fi
    else
        mount /dev/mapper/storage-root /mnt
        if [ $? -ne 0 ]; then
            bail "mount returned a non-zero error code!"
        fi
    fi
    log "Drive root partition mounted to \"/mnt\".."
    mkdir /mnt/boot
    mount "${SETUP_DRIVE}1" /mnt/boot
    if [ $? -ne 0 ]; then
        bail "mount returned a non-zero error code!"
    fi
    log "Drive boot partition mounted to \"/mnt/boot\".."
    return 0
}

setup_files() {
    pkgs=( "base" "net-tools" "openssh" "reflector" "linux-hardened" "pacman-contrib" "git" )
    if [[ "$SETUP_FS" == "btrfs" ]]; then
        pkgs+=("btrfs-progs")
    fi
    if [ $SETUP_EFI -eq 1 ]; then
        pkgs+=("efibootmgr")
    else
        pkgs+=("grub")
    fi
    log "Installing Packages to root.."
    pacstrap /mnt ${pkgs[@]}
    if [ $? -ne 0 ]; then
        bail "pacstrap returned a non-zero error code!"
    fi
    log "Package install complete!"
    return 0
}

setup_config() {
    log "Starting system configuration.."
    mkdir -p "${SETUP_DIRECTORY}/bin"
    mkdir -p "${SETUP_DIRECTORY}/etc/ssh"
    mkdir -p "${SETUP_DIRECTORY}/etc/iptables"
    mkdir -p "${SETUP_DIRECTORY}/etc/sysctl.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/profile.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/syscheck.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/modprobe.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/udev/rules.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/pacman.d/hooks"
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system"
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/network"
    mkdir -p "${SETUP_DIRECTORY}/etc/security/limits.d"
    mkdir -p /mnt/etc/systemd/system/timers.target.wants
    mkdir -p /mnt/etc/systemd/system/sockets.target.wants
    mkdir -p /mnt/etc/systemd/system/sysinit.target.wants
    mkdir -p /mnt/etc/systemd/system/network-online.target.wants
    for nic in ${SETUP_NET[@]}; do
        name=$(echo $nic | awk -F, '{print $1}')
        alias=$(echo $nic | awk -F, '{print $2}')
        address=$(echo $nic | awk -F, '{print $3}')
        gateway=$(echo $nic | awk -F, '{print $4}')
        dns1=$(echo $nic | awk -F, '{print $5}')
        dns2=$(echo $nic | awk -F, '{print $6}')
        log "Configuring Interface \"$name\".."
        if ! [ -z "$alias" ]; then
            mac=$(ip link show $name | grep ether | awk '{print $2}')
            printf "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"$mac\", NAME=\"$alias\"\n" >> "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            chmod 400 "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            name="$alias"
        fi
        printf "[Match]\nName=$name\n\n" > "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        if [ -z "$address" ]; then
            printf "[Network]\nDHCP=yes\n\n[DHCP]\nUseDomains=yes\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        else
            printf "[Network]\nAddress=$address\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        fi
        if ! [ -z "$dns1" ]; then
            printf "DNS=$dns1\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        fi
        if ! [ -z "$dns2" ]; then
            printf "DNS=$dns2\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        fi
        if ! [ -z "$gateway" ]; then
            printf "\n[Route]\nGateway=$gateway\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
        fi
        chmod 444 "${SETUP_DIRECTORY}/etc/systemd/network/$name.network"
    done
    touch "${SETUP_DIRECTORY}/etc/vconsole.conf"
    touch "${SETUP_DIRECTORY}/etc/syscheck.d/empty.sh"
    if [ $SETUP_EFI -eq 0 ]; then
        sed -i -e 's/part_gpt part_msdos/part_gpt lvm part_msdos/g' "/mnt/etc/default/grub"
    fi
    printf 'FILES=()\nCOMPRESSION="gzip"\nMODULES=()\nBINARIES=(' > "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    if [[ "$SETUP_FS" == "btrfs" ]]; then
        printf '"/usr/bin/btrfs")\nHOOKS=(systemd autodetect modconf keymap block keyboard sd-vconsole sd-lvm2 btrfs filesystems fsck)\n' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    else
        printf ')\nHOOKS=(systemd autodetect modconf keymap block keyboard sd-vconsole sd-lvm2 filesystems fsck)\n' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    printf "$SETUP_HOSTNAME\n" > "${SETUP_DIRECTORY}/etc/motd"
    printf "$SETUP_HOSTNAME" > "${SETUP_DIRECTORY}/etc/hostname"
    printf '#!/usr/bin/bash\n# Relinks files to their respective directories.\n# iDigitalFlame' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '\n\nDEBUG=0\n\nif [ $# -ne 2 ]; then\n    printf "relink <config source> <config targ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'et> [debug]\\n"\n    exit 1\nfi\n\nif [ $# -eq 3 ]; then\n    DEBUG=1\nfi\n\nlist() {\n   ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf ' if [ $# -ne 2 ]; then\n        return 1\n    fi\n    fc=${1%%/}\n    ft=${2%%/}\n    f' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'l=$(find "$fc" -type f -print)\n    for file in $fl; do\n        fp=$(printf "$fil' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'e" | awk "{gsub(\\"${fc}\\", \\"\\"); print \\$1}")\n        if ! [ -z $(echo $fp | gr' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'ep -vE '\''\\.(nlk|nolink)$'\'' | grep -vE '\''^\\/\\.git(\\/|ignore$|config$)'\'' | grep -vE '\''^' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '\\/(LICENSE|license)$'\'' | grep -vE '\''^\\/[a-zA-Z0-9_.]+\\.(md|MD|code-workspace)$'\'') ]' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '; then\n            check "$ft$fp" "$fc$fp"\n        fi\n    done\n    return 0\n}\n\nl' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'ink() {\n    if [ $# -ne 2 ]; then\n        return 1\n    fi\n    rm -f "$1" 2> /dev' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '/null\n    fd=$(dirname "$1")\n    if ! [ -d "$fd" ]; then\n        printf "Making ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '$fd\\n"\n        mkdir -p "$fd" 2> /dev/null\n        if [ $? -ne 0 ]; then\n       ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '     panic "Cannot create directory \\"$fd\\"!"\n        fi\n        if [ $UID -eq 0' >> "${SETUP_DIRECTORY}/bin/relink"
    printf ' ]; then\n            chmod 555 "$fd"\n        else\n            chmod 755 "$fd"\n  ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '      fi\n    fi\n    ln -s "$2" "$1"\n    if [ $? -ne 0 ]; then\n        panic "Cou' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'ld not link \\"$1\\" to \\"$2\\"!"\n    fi\n    printf "[+] Relinked \\"$1\\" to \\"$2\\".' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '\\n"\n    return 0\n}\n\ncheck() {\n    if [ $# -ne 2 ]; then\n        return 1\n    fi\n' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '    if [ $DEBUG -eq 1 ]; then\n        printf "[+] Checking \\"$1\\".. \\n"\n    fi\n ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '   if ! [ -L "$1" ]; then\n        printf "File \\"$1\\" is invalid, updating!\\n"\n ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '       link "$1" "$2"\n    else\n        fl=$(ls -al "$1" | awk '\''{print $11}'\'')\n   ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '     if ! [[ "$fl" == "$2" ]]; then\n            printf "File \\"$1\\" is invalid, ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'updating!\\n"\n            link "$1" "$2"\n        else\n            if [ $DEBUG -eq' >> "${SETUP_DIRECTORY}/bin/relink"
    printf ' 1 ]; then\n                printf "File \\"$1\\" is valid!\\n"\n            fi\n     ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '   fi\n    fi\n    return 0\n}\n\npanic() {\n    printf "[!] $1\\n"\n    exit 1\n}\n\nif ! ' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '[ -d "$1" ]; then\n    panic "Config source \\"$1\\" does not exist!"\nfi\n\nif ! [ -d' >> "${SETUP_DIRECTORY}/bin/relink"
    printf ' "$2" ]; then\n    mkdir -p "$2"\n    if [ $? -ne 0 ]; then\n        panic "Could n' >> "${SETUP_DIRECTORY}/bin/relink"
    printf 'ot create target directory \\"$2\\"!"\n    fi\nfi\n\nlist "$1" "$2"\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/relink"
    printf '#!/usr/bin/bash\n# Preforms basic system information display checks.\n# iDigitalFl' >> "${SETUP_DIRECTORY}/bin/syscheck"
    printf 'ame\n\npause() {\n    printf "Press ENTER to continue.."\n    read -s\n    printf "\\n' >> "${SETUP_DIRECTORY}/bin/syscheck"
    printf '"\n}\n\nuname -a\npause\nsystemctl --failed\npause\nifconfig\npause\nnetstat -panut\npause' >> "${SETUP_DIRECTORY}/bin/syscheck"
    printf '\nps xfua\npause\ndf -h\npause\nmount\npause\npacman -Syy 1> /dev/null\nprintf "Orphaned' >> "${SETUP_DIRECTORY}/bin/syscheck"
    printf ' Packages Found:\\n"\npacman -Qtdq\nprintf "Done!\\n"\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/syscheck"
    printf '#!/usr/bin/bash\n# Wrapper and permissions fix-er for "relink".\n# iDigitalFlame\n\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'source "/etc/sysconfig.conf" 2> /dev/null\nif [ $? -ne 0 ]; then\n    printf '\''Coul' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'd not locate or source "/etc/sysconfig.conf"!\\n'\''\n    exit 1\nfi\nif [ -z "$SYSCONF' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'IG" ]; then\n    printf '\''Could not find System Configuration directory!\\n'\''\n    ex' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'it 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf "System Configuration director' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'y \\"$SYSCONFIG\\" does not exist!\\n"\n    exit 1\nfi\nSYSCONFIG=${SYSCONFIG%%/}\n\nif [' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf ' $UID -ne 0 ]; then\n    printf "Only root can do this!\\n"\n    exit 1\nfi\n\nrelink ' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '"$SYSCONFIG" /\n\npacman -Qeq 1> "${SYSCONFIG}/packages.md"\ncp /etc/fstab "${SYSCO' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'NFIG}/etc/fstab.nlk"\n\nchown -R root:root "$SYSCONFIG"\nchmod -R 555 "$SYSCONFIG"\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '\nfind "$SYSCONFIG" -type f -exec chmod 444 {} \\;\nfind "$SYSCONFIG" -type d -exec' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf ' chmod 555 {} \\;\n\nchmod -R 555 "${SYSCONFIG}/bin"\nchmod -R 555 "${SYSCONFIG}/etc' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '/profile.d"\nchmod -R 500 "${SYSCONFIG}/etc/syscheck.d"\n\nchmod 555 "${SYSCONFIG}/' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'etc/ssh"\nchmod 500 "${SYSCONFIG}/etc/sysctl.d"\nchmod 500 "${SYSCONFIG}/etc/iptab' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'les"\nchmod 500 "${SYSCONFIG}/etc/modprobe.d"\nchmod 500 "${SYSCONFIG}/etc/pacman.' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'd/hooks"\nchmod 400 "${SYSCONFIG}/etc/mkinitcpio.conf"\nchmod 440 "${SYSCONFIG}/et' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'c/ssh/sshd_config"\nchmod 500 "${SYSCONFIG}/etc/security/limits.d"\nchmod 400 "${S' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'YSCONFIG}/etc/sysctl.d/kernel.conf"\nchmod 400 "${SYSCONFIG}/etc/systemd/coredump' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '.conf"\nchmod 400 "${SYSCONFIG}/etc/iptables/iptables.rules"\nchmod 400 "${SYSCONF' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'IG}/etc/iptables/ip6tables.rules"\nchmod 400 "${SYSCONFIG}/etc/security/limits.d/' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'limits.conf"\n\nchmod 400 ${SYSCONFIG}/etc/modprobe.d/*\nchmod 400 ${SYSCONFIG}/etc' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '/pacman.d/hooks/*\n\nchmod -R 555 /etc/profile.d\nchmod -R 500 /etc/syscheck.d\n\nchm' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'od 555 /etc/ssh\nchmod 500 /etc/sysctl.d\nchmod 500 /etc/iptables\nchmod 500 /etc/m' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'odprobe.d\nchmod 500 /etc/pacman.d/hooks\nchmod 500 /etc/security/limits.d\n\nif [ -' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'd "/etc/syscheck.d" ]; then\n    for s in $(ls /etc/syscheck.d/*.sh); do\n        ' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'source "$s"\n    done\nfi\n\nprintf "Broken Links Found:\\n"\nfind /etc/ -xtype l 2> /' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'dev/null | grep -v "/proc" | grep -v "/tmp" | grep -v "/run"\nprintf "Done!\\n"\nex' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf 'it 0\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    printf '#!/usr/bin/bash\n# Attempts to pull the latest configuration information from a G' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'it repo.\n# iDigitalFlame\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ $? -ne ' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf '0 ]; then\n    printf '\''Could not locate or source "/etc/sysconfig.conf"!\\n'\''\n    e' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'xit 1\nfi\nif [ -z "$SYSCONFIG" ]; then\n    printf '\''Could not find System Configur' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'ation directory!\\n'\''\n    exit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf "Sys' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'tem Configuration directory \\"$SYSCONFIG\\" does not exist!\\n"\n    exit 1\nfi\nSYSC' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'ONFIG=${SYSCONFIG%%/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    printf "System Co' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'nfiguration directory \\"$SYSCONFIG\\" is not a Git repo!\\n"\n    exit 1\nfi\n\nif [ $' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf 'UID -ne 0 ]; then\n    printf "Only root can do this!\\n"\n    exit 1\nfi\n\nsh -c "cd' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf ' ${SYSCONFIG}; git pull"\nsyslink\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/syspull"
    printf '#!/usr/bin/bash\n# Attempts to push the latest configuration information to a Git' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf ' repo.\n# iDigitalFlame\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ $? -ne 0 ' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf ']; then\n    printf '\''Could not locate or source "/etc/sysconfig.conf"!\\n'\''\n    exi' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 't 1\nfi\nif [ -z "$SYSCONFIG" ]; then\n    printf '\''Could not find System Configurat' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 'ion directory!\\n'\''\n    exit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf "Syste' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 'm Configuration directory \\"$SYSCONFIG\\" does not exist!\\n"\n    exit 1\nfi\nSYSCON' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 'FIG=${SYSCONFIG%%/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    printf "System Conf' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 'iguration directory \\"$SYSCONFIG\\" is not a Git repo!\\n"\n    exit 1\nfi\n\nif [ $UI' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf 'D -ne 0 ]; then\n    printf "Only root can do this!\\n"\n    exit 1\nfi\n\nsh -c "cd $' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf '{SYSCONFIG}; git add -A .; git commit -m '\''syspush'\''; git push"\nsyslink\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/syspush"
    printf '#!/usr/bin/bash\n# Attempts to update the system and relink any broken configurat' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    printf 'ion links.\n# iDigitalFlame\n\nif [ $UID -ne 0 ]; then\n    printf "Only root can do' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    printf ' this!\\n"\n    exit 1\nfi\n\npacman -Syu\nsyslink\nsystemctl start checkupdates.servic' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    printf 'e\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    printf '*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT DROP [0:0]\n:BASE - [0:0]' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '\n-A INPUT -j BASE\n-A OUTPUT -j BASE\n-A BASE -i lo -j ACCEPT\n-A BASE -s ::1/128 -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'd ::1/128 -j ACCEPT\n-A BASE -m state --state INVALID -j DROP\n-A BASE -p tcp -m s' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'tate --state RELATED,ESTABLISHED -j ACCEPT\n-A BASE -p udp -m state --state RELAT' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'ED,ESTABLISHED -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 1 -j ACCEPT' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 2 -j ACCEPT\n-A BASE -p ipv6-icmp -m' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf ' icmp6 --icmpv6-type 3 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 4 -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 133 -j ACCEPT\n-A BASE -p ip' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'v6-icmp -m icmp6 --icmpv6-type 134 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icm' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'pv6-type 135 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 136 -j ACCEPT' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 137 -j ACCEPT\n-A BASE -p ipv6-icmp -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'm icmp6 --icmpv6-type 141 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type ' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '142 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 148 -j ACCEPT\n-A BASE -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'p ipv6-icmp -m icmp6 --icmpv6-type 149 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-ic' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'mp -m icmp6 --icmpv6-type 130 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icm' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'p6 --icmpv6-type 131 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmp' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'v6-type 132 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 1' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '43 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 151 -j ACC' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'EPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 152 -j ACCEPT\n-A BA' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'SE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 153 -j ACCEPT\n-A BASE -p ipv' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '6-icmp -m icmp6 --icmpv6-type 129 -m limit --limit 1/sec -j ACCEPT\n-A BASE -m ic' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'mp6 -p ipv6-icmp --icmpv6-type 128 -m limit --limit 1/sec -j ACCEPT\n-A OUTPUT -m' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf ' tcp -p tcp --dport 53 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 53 -j ACCEPT\n-A' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf ' OUTPUT -m tcp -p tcp --dport 80 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 80 -j' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf ' ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 443 -j ACCEPT\n-A OUTPUT -m udp -p udp --' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'dport 443 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 123 -j ACCEPT\n-A OUTPUT -m t' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'cp -p tcp --dport 11371 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 546:547 -j ACC' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf 'EPT\n-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT\nCOMMIT\n' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    printf '*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT DROP [0:0]\n:BASE - [0:0]' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf '\n-A INPUT -j BASE\n-A OUTPUT -j BASE\n-A BASE -i lo -j ACCEPT\n-A BASE -s 127.0.0.1' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf '/32 -d 127.0.0.1/32 -j ACCEPT\n-A BASE -p icmp -m icmp --icmp-type 3 -j ACCEPT\n-A' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf ' BASE -p icmp -m icmp --icmp-type 3/1 -j ACCEPT\n-A BASE -p icmp -m icmp --icmp-t' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'ype 0 -m limit --limit 1/sec -j ACCEPT\n-A BASE -p icmp -m icmp --icmp-type 8 -m ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'limit --limit 1/sec -j ACCEPT\n-A BASE -f -j DROP\n-A BASE -d 0.0.0.0/32 -j DROP\n-' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'A BASE -s 224.0.0.0/8 -j DROP\n-A BASE -d 224.0.0.0/8 -j DROP\n-A BASE -d 255.255.' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf '255.255/32 -j DROP\n-A BASE -s 255.255.255.255/32 -j DROP\n-A BASE -m state --stat' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'e INVALID -j DROP\n-A BASE -f -m limit --limit 10/min -j ACCEPT\n-A BASE -m addrty' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'pe --dst-type ANYCAST -j DROP\n-A BASE -m addrtype --dst-type BROADCAST -j DROP\n-' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'A BASE -m addrtype --dst-type MULTICAST -j DROP\n-A BASE -p tcp -m state --state ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'RELATED,ESTABLISHED -j ACCEPT\n-A BASE -p udp -m state --state RELATED,ESTABLISHE' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'D -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 53 -j ACCEPT\n-A OUTPUT -m udp -p udp' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf ' --dport 53 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 80 -j ACCEPT\n-A OUTPUT -m ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'udp -p udp --dport 80 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 443 -j ACCEPT\n-A' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf ' OUTPUT -m udp -p udp --dport 443 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 123 -' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 11371 -j ACCEPT\n-A OUTPUT -m udp -p udp' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf ' --dport 67:68 -j ACCEPT\n-A INPUT -m tcp -p tcp --dport 22 -j ACCEPT\nCOMMIT\n' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    printf 'blacklist pcspkr\n' >> "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"
    printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperation  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    printf ' = Upgrade\n\n[Action]\nDescription = Finding orphan packages..\nWhen        = PostT' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    printf 'ransaction\nExec        = /usr/bin/bash -c "pacman -Qtdq || echo '\''No orphans foun' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    printf 'd.'\''"\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperation  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    printf ' = Upgrade\n\n[Action]\nDescription = Looking for *.pac* files..\nWhen        = Post' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    printf 'Transaction\nExec        = /usr/bin/bash -c "find /etc/ -type f -name *.pac* -ls"' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    printf '\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperation  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    printf ' = Upgrade\nOperation   = Install\n\n[Action]\nDescription = Fixing permissions for ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    printf 'system files..\nWhen        = PostTransaction\nExec        = /usr/bin/syslink\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    printf '[Trigger]\nType        = Package\nTarget      = iptables\nOperation   = Upgrade\n\n[A' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    printf 'ction]\nDescription = Removing simple rules files..\nWhen        = PostTransaction' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    printf '\nExec        = /usr/bin/bash -c "rm /etc/iptables/simple_firewall.rules; rm /etc' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    printf '/iptables/empty.rules"\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    printf '[Trigger]\nType        = Package\nTarget      = pacman-mirrorlist\nOperation   = Up' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf 'grade\n\n[Action]\nDescription = Updating pacman-mirrorlist with reflector and remo' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf 'ving pacnew..\nWhen        = PostTransaction\nExec        = /usr/bin/bash -c "refl' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf 'ector --protocol https --latest 30 --number 20 --sort rate --threads 5 --country' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf ' '\''United States'\'' --save /etc/pacman.d/mirrorlist; if [[ -f /etc/pacman.d/mirrorl' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf 'ist.pacnew ]]; then rm /etc/pacman.d/mirrorlist.pacnew; fi"\nDepends     = reflec' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf 'tor\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperation  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    printf ' = Upgrade\n\n[Action]\nDescription = Removing old cached packages..\nWhen        = ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    printf 'PostTransaction\nExec        = /usr/bin/bash -c "paccache -rk2; paccache -ruk0"\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    printf '#!/usr/bin/bash\n\nalias nano="nano -Ll"\n' >> "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"
    printf '#!/usr/bin/bash\n\nHISTSIZE=500\nHISTFILESIZE=0\nHISTFILE=/dev/null\n' >> "${SETUP_DIRECTORY}/etc/profile.d/history.sh"
    printf '#!/usr/bin/bash\n\numask 027\n' >> "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"
    printf '#!/usr/bin/bash\n\n_disks() {\n    printf "# Disks:\\n"\n    df -h | grep -v "tmpfs" ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '| grep -E '\''/dev/|/opt/|/mnt/'\'' | sort -r | awk '\''{print ""$1" "$5" ("$3"/"$2")"}'\'' ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '| column -t | awk '\''{print "#     "$0}'\''\n}\n\n_synced() {\n    source "/etc/sysconfig' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '.conf" 2> /dev/null\n    if [ $? -ne 0 ]; then\n        return 0\n    fi\n    if [ -' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'z "$SYSCONFIG" ]; then\n        return 0\n    fi\n    if ! [ -d "$SYSCONFIG" ]; the' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'n\n        return 0\n    fi\n    SYSCONFIG=${SYSCONFIG%%/}\n    if ! [ -d "${SYSCONFI' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'G}/.git" ]; then\n        return 0\n    fi\n    if ! [[ -z $(bash -c "cd ${SYSCONFI' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'G}; git status | grep -iE '\''modified|deleted|Untracked'\''") ]]; then\n        printf' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf ' '\''# Config Repo:\\tSync needed, use "syspush"\\n'\''\n    else\n        printf "# Confi' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'g Repo:\\tUp-to-Date\\n"\n    fi\n}\n\n_uptime() {\n    ut=$(uptime --pretty | sed '\''s/u' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'p //g'\'')\n    printf "# Uptime:\\t$ut\\n"\n    printf "# Kernel:\\t$(uname -r)\\n"\n}\n\n_' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'network() {\n    printf "# Network Addresses:\\n"\n    for addr in $(ifconfig | gre' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'p "inet" | grep -v "::1" | grep -v "127.0.0.1" | grep -v "<link>" | awk '\''{print ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '$2}'\''); do\n        printf "#     $addr\\n"\n    done\n}\n\n_services() {\n    sl=$(nets' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'tat -panut 2>/dev/null | grep LISTEN | wc -l)\n    se=$(netstat -panut 2>/dev/nul' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'l | grep ESTABLISHED | wc -l)\n    st=$(systemctl --all --no-legend --no-pager | ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'grep ".timer" | wc -l)\n    sa=$(systemctl --state=active --no-legend --no-pager ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '| grep ".service" | grep "running" | wc -l)\n    sf=$(systemctl --state=failed --' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'no-legend --no-pager | grep ".service" | wc -l)\n    if [ -f "/var/run/updates.li' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'st" ]; then\n        ul="$(cat "/var/run/updates.list" | wc -l) Pending"\n    else' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '\n        if [ $UID -eq 0 ]; then\n            systemctl start checkupdates.servic' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'e\n            ul="Checking for updates.."\n        else\n            ul="Updates c' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'heck pending.."\n        fi\n    fi\n    printf "# Updates:\\t$ul\\n"\n    printf "# C' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'onnections:\\t$se Established, $sl Listening\\n"\n    printf "# Services:\\t$sa Runn' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'ing, $sf Failed, $st Timers\\n"\n}\n\nif [[ $- != *i* ]] || [ ! -z "$SSH_CLIENT" ]; ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf 'then\n    printf "###############################################################' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '##############\\n"\n    _disks\n    _network\n    _uptime\n    _synced\n    _services\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '    printf "####################################################################' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '#########\\n"\nfi\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    printf '* hard core 0\n* soft nproc 2500\n* hard nproc 5000\n' >> "${SETUP_DIRECTORY}/etc/security/limits.d/limits.conf"
    printf 'Host *\n    Port                            22\n    MACs                          ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '  hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@opens' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'sh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com\n    Tunnel              ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '            no\n    Ciphers                         chacha20-poly1305@openssh.com' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf ',aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr\n' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '    Protocol                        2\n    BatchMode                       no\n   ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf ' ForwardX11                      no\n    CheckHostIP                     yes\n    ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'IdentityFile                    ~/.ssh/id_rsa\n    IdentityFile                  ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '  ~/.ssh/id_ed25519\n    ForwardAgent                    no\n    KexAlgorithms    ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '               curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '\n    VisualHostKey                   yes\n    AddressFamily                   any' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '\n    ConnectTimeout                  30\n    HashKnownHosts                  yes\n' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf '    HostKeyAlgorithms               ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cer' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 't-v01@openssh.com,ssh-ed25519,ssh-rsa\n    PermitLocalCommand              no\n   ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf ' GSSAPIAuthentication            no\n    PubkeyAuthentication            yes\n    ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'StrictHostKeyChecking           ask\n    PasswordAuthentication          no\n    H' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'ostbasedAuthentication         no\n    GSSAPIDelegateCredentials       no\n    Cha' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'llengeResponseAuthentication yes\n' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    printf 'Port                            22\nMACs                            hmac-sha2-512-' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '512,hmac-sha2-256,umac-128@openssh.com\nUsePAM                          yes\nCiphe' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'rs                         chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr\nHostKey                 ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '        /etc/ssh/ssh_host_rsa_key\nHostKey                         /etc/ssh/ssh_h' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'ost_ed25519_key\nProtocol                        2\nSubsystem                     ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '  sftp /usr/lib/ssh/sftp-server\nPrintMotd                       no\nPermitTTY    ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '                   yes\nCompression                     no\nMaxStartups           ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '          10:30:100\nGatewayPorts                    no\nPermitTunnel             ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '       no\nPrintLastLog                    yes\nIgnoreRhosts                    ye' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 's\nTCPKeepAlive                    yes\nAddressFamily                   any\nListen' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'Address                   0.0.0.0\nKexAlgorithms                   curve25519-sha' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '256@libssh.org,diffie-hellman-group-exchange-sha256\nLoginGraceTime              ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '    1m\nPermitRootLogin                 yes\nAllowTcpForwarding              no\nAu' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'thorizedKeysFile              .ssh/authorized_keys\nClientAliveCountMax          ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '   0\nClientAliveInterval             600\nIgnoreUserKnownHosts            no\nPerm' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'itEmptyPasswords            no\nAllowAgentForwarding            no\nPubkeyAuthenti' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'cation            yes\nPasswordAuthentication          no\nKerberosAuthentication ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '         no\nHostbasedAuthentication         no\nChallengeResponseAuthentication n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf 'o\n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    printf '#!/usr/bin/bash\n\nchmod 555 /etc/ssh\nchmod 550 /etc/iptables\nchmod 440 /etc/iptab' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'les/*\nchmod 555 -R /etc/systemd\nchmod 550 -R /etc/security\nchmod 550 -R /etc/pac' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'man.d\nchmod 550 -R /etc/sysctl.d\nchmod 555 -R /etc/profile.d\nchmod 555 -R /etc/s' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'yscheck.d\nchmod 550 -R /etc/modprobe.d\n\nchown root:root -R /etc/systemd\nchown ro' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'ot:root -R /etc/iptables\nchown root:root -R /etc/pacman.d\nchown root:root -R /et' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'c/security\nchown root:root -R /etc/sysctl.d\nchown root:root -R /etc/profile.d\nch' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'own root:root -R /etc/syscheck.d\nchown root:root -R /etc/modprobe.d\n\nfind /etc/s' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'sh -type f -exec chmod 400 {} \\;\nfind /etc/systemd -type f -exec chmod 444 {} \\;' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf '\nfind /etc/pacman.d -type f -exec chmod 440 {} \\;\nfind /etc/sysctl.d -type f -ex' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'ec chmod 440 {} \\;\nfind /etc/security -type f -exec chmod 440 {} \\;\nfind /etc/mo' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'dprobe.d -type f -exec chmod 440 {} \\;\n\nchmod 444 /etc/motd\nchmod 444 /etc/hosts' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf '\nchmod 444 /etc/hostname\nchmod 444 /etc/locale.gen\nchmod 400 /etc/pacman.conf\nch' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'mod 400 /etc/vconsole.conf\nchmod 444 /etc/sysconfig.conf\nchmod 444 /etc/ssh/ssh_' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'config\nchmod 400 /etc/mkinitcpio.conf\n\nchown root:root /etc/motd\nchown root:root' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf ' /etc/hosts\nchown root:root /etc/hostname\nchown root:root /etc/locale.gen\nchown ' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'root:root /etc/pacman.conf\nchown root:root /etc/vconsole.conf\nchown root:root /e' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'tc/sysconfig.conf\nchown root:root /etc/mkinitcpio.conf\n' >> "${SETUP_DIRECTORY}/etc/syscheck.d/perms.sh"
    printf 'net.ipv6.conf.all.use_tempaddr      = 2\nnet.ipv6.conf.default.use_tempaddr  = 2\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/ipv6.conf"
    printf 'fs.file-max                     = 372925\nvm.swappiness                   = 10\nke' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    printf 'rnel.kptr_restrict            = 2\nkernel.dmesg_restrict           = 1\nfs.protect' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    printf 'ed_symlinks           = 1\nfs.protected_hardlinks          = 1\nkernel.yama.ptrace' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    printf '_scope        = 1\nfs.inotify.max_user_watches     = 65536\nvm.dirty_writeback_cen' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    printf 'tisecs    = 1500\nfs.inotify.max_user_instances   = 1024\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    printf 'net.core.rmem_max                           = 16777216\nnet.ipv4.tcp_rmem        ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '                   = 4096 1048576 2097152\nnet.ipv4.tcp_wmem                     ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '      = 4096 65536 16777216\nnet.core.wmem_max                           = 167772' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '16\nnet.core.somaxconn                          = 1024\nnet.core.optmem_max       ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '                  = 65536\nnet.ipv4.tcp_rfc1337                        = 1\nnet.ip' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'v4.udp_rmem_min                       = 8192\nnet.ipv4.udp_wmem_min              ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '         = 8192\nnet.core.rmem_default                       = 1048576\nnet.core.w' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'mem_default                       = 1048576\nnet.ipv4.tcp_fastopen               ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '        = 1\nnet.ipv4.tcp_tw_reuse                       = 1\nnet.core.netdev_budg' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'et                      = 50000\nnet.ipv4.tcp_timestamps                     = 1\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'net.core.bpf_jit_harden                     = 1\nnet.ipv4.tcp_syncookies         ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '            = 1\nnet.ipv4.tcp_low_latency                    = 1\nnet.ipv4.tcp_fin' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '_timeout                    = 10\nnet.core.netdev_max_backlog                 = 1' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '00000\nnet.ipv4.tcp_max_tw_buckets                 = 2000000\nnet.ipv4.conf.all.rp' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '_filter                 = 2\nnet.core.netdev_budget_usecs                = 5000\nn' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'et.ipv4.tcp_max_syn_backlog                = 65535\nnet.ipv4.ip_local_port_range ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '               = 1025 65535\nnet.ipv4.conf.default.rp_filter             = 2\nnet.' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'ipv4.conf.all.send_redirects            = 0\nnet.ipv6.conf.all.accept_redirects  ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '        = 0\nnet.ipv4.conf.all.accept_redirects          = 0\nnet.ipv4.tcp_slow_st' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'art_after_idle          = 0\nnet.ipv4.icmp_echo_ignore_broadcasts        = 1\nnet.' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'ipv4.conf.default.send_redirects        = 0\nnet.ipv4.conf.default.accept_redirec' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf 'ts      = 0\nnet.ipv6.conf.default.accept_redirects      = 0\nnet.ipv4.icmp_ignore' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '_bogus_error_responses  = 1\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    printf '[Unit]\nDescription = Check Updates Status Service\nAfter       = network-online.t' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.service"
    printf 'arget\nRequires    = network-online.target\n\n[Service]\nType        = simple\nExecSt' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.service"
    printf 'art   = /usr/bin/bash -c "checkupdates > /var/run/updates.list"\n\n[Install]\nWante' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.service"
    printf 'dBy    = multi-user.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.service"
    printf '[Unit]\nDescription = Check Updates Status Timer\n\n[Timer]\nOnCalendar  = daily\nAcc' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.timer"
    printf 'uracySec = 15m\n\n[Install]\nWantedBy    = timers.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/checkupdates.timer"
    printf '[Unit]\nDescription = Pacman Mirrorlist Update Service\nAfter       = network-onli' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf 'ne.target systemd-resolved.service\nRequires    = network-online.target systemd-r' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf 'esolved.service\n\n[Service]\nType        = simple\nExecStart   = /usr/bin/reflector' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf ' --protocol https --latest 30 --number 20 --sort rate --threads 5 --country '\''Uni' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf 'ted States'\'' --save /etc/pacman.d/mirrorlist\n\n[Install]\nRequiredBy  = multi-user.' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf 'target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    printf '[Unit]\nDescription         = Pacman Mirrorlist Update Timer\n\n[Timer]\nOnCalendar ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    printf '         = weekly\nPersistent          = true\nRandomizedDelaySec  = 12h\n\n[Install' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    printf ']\nWantedBy            = timers.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    printf '[Coredump]\nStorage = none\n' >> "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"
    printf '[Journal]\nStorage             = persistent\nMaxFileSec          = 1day\nSystemMaxU' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    printf 'se        = 200M\nMaxLevelStore       = notice\nForwardToSyslog     = no\nSystemMax' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    printf 'FileSize   = 10M\n' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    printf '[Resolve]\nLLMNR           = no\nDNSSEC          = allow-downgrade\nDNSStubListener' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    printf ' = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    printf '[Time]\nNTP = time.nist.gov time-a-g.nist.gov time-b-g.nist.gov\n' >> "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    printf 'en_US.UTF-8 UTF-8\nen_US       ISO-8859-1\n' >> "${SETUP_DIRECTORY}/etc/locale.gen"
    printf '[options]\nDBPath              = /var/lib/pacman/\nGPGDir              = /etc/pacm' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'an.d/gnupg/\nRootDir             = /\nHookDir             = /etc/pacman.d/hooks/\nL' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'ogFile             = /var/log/pacman.log\nHoldPkg             = pacman glibc\nCach' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'eDir            = /var/cache/pacman/pkg/\nUseDelta            = 0.7\nSigLevel     ' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf '       = Required DatabaseOptional\nCleanMethod         = KeepInstalled\nArchitect' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'ure        = auto\nLocalFileSigLevel   = Optional\n\nCheckSpace\nTotalDownload\nVerbo' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'sePkgLists\n\n[core]\nInclude             = /etc/pacman.d/mirrorlist\n[extra]\nInclud' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'e             = /etc/pacman.d/mirrorlist\n[community]\nInclude             = /etc/' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf 'pacman.d/mirrorlist\n' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    printf "127.0.0.1    localhost\n172.0.0.1    $(hostname)\n" >> "${SETUP_DIRECTORY}/etc/hosts"
    printf "SYSCONFIG=${SETUP_CONFIGURATION}\n" > "/mnt/etc/sysconfig.conf"
    chmod 555 "${SETUP_DIRECTORY}/bin"
    chmod 555 "${SETUP_DIRECTORY}/etc/ssh"
    chmod 550 "${SETUP_DIRECTORY}/etc/sysctl.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/iptables"
    chmod 555 "${SETUP_DIRECTORY}/etc/profile.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/syscheck.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/modprobe.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/syscheck.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/udev/rules.d"
    chmod 550 "${SETUP_DIRECTORY}/etc/pacman.d/hooks"
    chmod 555 "${SETUP_DIRECTORY}/etc/systemd/system"
    chmod 555 "${SETUP_DIRECTORY}/etc/pacman.d/hooks"
    chmod 555 "${SETUP_DIRECTORY}/etc/systemd/network"
    chmod 550 "${SETUP_DIRECTORY}/etc/security/limits.d"
    chmod 555 /mnt/etc/systemd/system/timers.target.wants
    chmod 555 /mnt/etc/systemd/system/sockets.target.wants
    chmod 555 /mnt/etc/systemd/system/sysinit.target.wants
    chmod 555 /mnt/etc/systemd/system/network-online.target.wants
    chmod 444 "/mnt/etc/sysconfig.conf"
    chmod 444 "${SETUP_DIRECTORY}/etc/motd"
    chmod 444 "${SETUP_DIRECTORY}/etc/hosts"
    chmod 444 "${SETUP_DIRECTORY}/etc/hostname"
    chmod 444 "${SETUP_DIRECTORY}/etc/locale.gen"
    chmod 400 "${SETUP_DIRECTORY}/etc/vconsole.conf"
    chmod 444 "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    chmod 440 "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    chmod 400 "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    chmod 400 "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    chmod 555 "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"
    chmod 500 "${SETUP_DIRECTORY}/etc/syscheck.d/empty.sh"
    chmod 400 "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    chmod 400 "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"
    chmod 444 "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    chmod 444 "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    chmod 400 "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"
    chmod 444 "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    chmod 400 "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    chmod 400 "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    chmod 400 "${SETUP_DIRECTORY}/etc/security/limits.d/limits.conf"
    chmod 555 "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    chmod 444 "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    chmod 555 ${SETUP_DIRECTORY}/bin/*
    chmod 400 ${SETUP_DIRECTORY}/etc/pacman.d/hooks/*
    chmod 444 ${SETUP_DIRECTORY}/etc/systemd/system/*
    rm -f /mnt/etc/ssh/*key* 2> /dev/null
    rm -f /mnt/etc/localtime 2> /dev/null
    rm -f /mnt/etc/resolv.conf 2> /dev/null
    rm -f /mnt/etc/iptables/empty.rules 2> /dev/null
    rm -f /mnt/etc/iptables/simple_firewall.rules 2> /dev/null
    awk '$5 > 2000' /mnt/etc/ssh/moduli > /mnt/etc/ssh/moduli
    ssh-keygen -t ed25519 -f /mnt/etc/ssh/ssh_host_ed25519_key -N "" < /dev/null > /dev/null
    ssh-keygen -t rsa -b 4096 -f /mnt/etc/ssh/ssh_host_rsa_key -N "" < /dev/null > /dev/null
    log "System configuration complete.."
    return 0
}

setup_chroot() {
    log "Building chroot.."
    mkdir /mnt/tmplvm
    mount --bind /run/lvm /mnt/tmplvm
    printf '#!/bin/bash\n\n' > /mnt/root/start.sh
    printf 'ln -s /tmplvm /run/lvm\n' >> /mnt/root/start.sh
    printf 'vgscan -v\n' >> /mnt/root/start.sh
    printf "bash ${SETUP_CONFIGURATION}/bin/relink ${SETUP_CONFIGURATION} /\n" >> /mnt/root/start.sh
    printf "bash ${SETUP_CONFIGURATION}/bin/syslink\n" >> /mnt/root/start.sh
    printf 'locale-gen\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/share/zoneinfo/America/New_York /etc/localtime\n' >> /mnt/root/start.sh
    printf 'mkinitcpio -p linux-hardened\n' >> /mnt/root/start.sh
    printf 'mkinitcpio -p linux\n' >> /mnt/root/start.sh
    printf 'printf "archlinux\\narchlinux" | passwd root\n' >> /mnt/root/start.sh
    if [ $SETUP_EFI -eq 1 ]; then
        printf "bootctl install\n" >> /mnt/root/start.sh
    else
        printf "grub-install $SETUP_DRIVE\n" >> /mnt/root/start.sh
        printf "grub-mkconfig -o /boot/grub/grub.cfg\n" >> /mnt/root/start.sh
        printf "grub-set-default 1\n" >> /mnt/root/start.sh
    fi
    printf "touch /run/systemd/resolve/resolv.conf &> /dev/null\n" >> /mnt/root/start.sh
    printf "ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf\n" >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/fstrim.timer /etc/systemd/system/timers.target.wants/fstrim.timer\n' >> /mnt/root/start.sh
    printf 'ln -s /etc/systemd/system/reflector.timer /etc/systemd/system/timers.target.wants/reflector.timer\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service\n' >> /mnt/root/start.sh
    printf 'ln -s /etc/systemd/system/checkupdates.timer /etc/systemd/system/timers.target.wants/checkupdates.timer\n' >> /mnt/root/start.sh
    printf 'ln -s /etc/systemd/system/reflector.service /etc/systemd/system/multi-user.target.wants/reflector.service\n' >> /mnt/root/start.sh
    printf 'ln -s /etc/systemd/system/checkupdates.service /etc/systemd/system/multi-user.target.wants/checkupdates.service\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service\n' >> /mnt/root/start.sh
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd-wait-online.service /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service\n' >> /mnt/root/start.sh
    printf 'rm /etc/systemd/system/emergency.target 2> /dev/null\n' >> /mnt/root/start.sh
    printf 'rm /etc/systemd/system/emergency.service 2> /dev/null\n' >> /mnt/root/start.sh
    printf 'ln -s /dev/null /etc/systemd/system/emergency.target\n' >> /mnt/root/start.sh
    printf 'ln -s /dev/null /etc/systemd/system/emergency.service\n' >> /mnt/root/start.sh
    if [ -e "/mnt/usr/bin/fsck.btrfs" ]; then
        printf 'cp /usr/bin/fsck.btrfs /usr/local/bin/\n'  >> /mnt/root/start.sh
    fi
    printf 'timedatectl set-ntp true\n' >> /mnt/root/start.sh
    printf 'reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist\n' >> /mnt/root/start.sh
    printf 'update-ca-trust\n' >> /mnt/root/start.sh
    printf "usermod -c \"Server $(hostname)\" root\n"
    printf "git config --global user.name \"Server $(hostname)\"\n" >> /mnt/root/start.sh
    printf "git config --global user.email \"$(hostname)@archlinux.com\"\n" >> /mnt/root/start.sh
    printf 'exit\n' >> /mnt/root/start.sh
    chmod 555 /mnt/root/start.sh
    genfstab -U -p /mnt > /mnt/etc/fstab
    printf 'tmpfs\t/dev/shm\ttmpfs\trw,noexec,nosuid,nodev\t0 0' >> /mnt/etc/fstab
    if [ $? -ne 0 ]; then
        bail "genfstab returned a non-zero error code!"
    fi
    if [[ "$SETUP_FS" != "xfs" ]]; then
        sed -i -e 's/relatime/noatime/g' /mnt/etc/fstab
    fi
    log "Build complete, starting chroot.."
    arch-chroot /mnt /root/start.sh
    if [ $? -ne 0 ]; then
        bail "arch-chroot returned a non-zero error code!"
    fi
    log "Chroot finished!"
    if [ $SETUP_EFI -eq 1 ]; then
        log "Configuring EFI boot.."
        bdisk=""
        bopts=""
        for disk in $(ls -al /dev/disk/by-uuid/ | awk '{print $9}' | grep '-'); do
            dmount=$(cat /mnt/etc/fstab | grep "UUID=$disk" | grep "/" | awk '{print $2}')
            if [[ "$dmount" == "/" && ${#dmount} -eq 1 ]]; then
                bdisk="$disk"
                bopts=$(cat /mnt/etc/fstab | grep "UUID=$disk" | grep "/" | awk '{print $4}' | sed 's/,/ /g')
            fi
        done
        if [ -z "$bdisk" ]; then
            bail "Could not find the correct bootdisk!"
        else
            log "Bootdisk is \"$bdisk\".."
            printf 'default\tarchlinux\ntimeout\t1\neditor\t0\n' > /mnt/boot/loader/loader.conf
            printf "title\tArch Linux\nlinux\t/vmlinuz-linux-hardened\ninitrd\t/initramfs-linux-hardened.img\noptions\troot=UUID=$bdisk $bopts\n" > /mnt/boot/loader/entries/archlinux.conf
        fi
    fi
    umount /mnt/tmplvm
    rmdir /mnt/tmplvm
    log "Deleting install script.."
    rm -f /mnt/root/start.sh
    return 0
}

setup_init
setup_disk
setup_files
setup_config

if ! [ -z "$SETUP_SCRIPT" ]; then
    source "$SETUP_SCRIPT"
fi

setup_chroot
sync

log "Done!"
log "Hit CTRL+C to stop reboot and unmount of disks!"
log "Rebooting in 5 seconds.."

sleep 3
log "Rebooting in 2 seconds.."
sleep 2

log "Unmounting and rebooting!"
umount /mnt/boot /mnt/
sync
reboot
