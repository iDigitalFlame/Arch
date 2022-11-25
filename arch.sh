#!/usr/bin/bash
# ArchLinux Install Helper Script
#
# Copyright (C) 2020 - 2022 iDigitalFlame
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

SETUP_EFI=1
SETUP_LVM=0
SETUP_NET=()
SETUP_AUTO=0
SETUP_REBOOT=1
SETUP_SSHKEY=""
SETUP_FS="btrfs"
SETUP_CHECK_NET=0
SETUP_DRIVE="/dev/sda"
SETUP_HOSTNAME="archlinux"
SETUP_CONFIGURATION="/opt/sysconfig"
SETUP_DIRECTORY="/mnt${SETUP_CONFIGURATION}"

_RESULT=""

log() {
    printf "[+] ${1}\n"
}

yes() {
    empty=0
    printf "[?] ${1} ["
    if [[ $# -eq 2 && "${2}" == "1" ]]; then
        empty=1
        printf "Y/n]? "
    else
        printf "y/N]? "
    fi
    read check
    if [[ $empty -eq 1 && -z "${check}" ]]; then
        return 0
    fi
    if [[ "${check}" == "Y" || "${check}" == "y" ]]; then
        return 0
    fi
    return 1
}

ask() {
    printf "[?] ${1}? "
    read check
    if [[ ! -z "${check}" ]]; then
        _RESULT="${check}"
        if [ $# -eq 2 ]; then
            return 1
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
    printf "[!] An error occured! ${1}\n"
    printf "[!] Cannot continue, quitting!\n"
    exit 1
}

setup_nic() {
    if [ $# -ne 1 ]; then
        return 1
    fi
    name=$1
    if yes "(${name}) Automatic Setup" 1; then
        SETUP_NET+=("${name},,,,,")
        return 0
    fi
    iname=$name
    if ask "(${iname}) Rename this interface"; then
        iname="${_RESULT}"
    fi
    if yes "(${iname}) Use DHCP for this interface" 1; then
        SETUP_NET+=("${name},${iname},,,,")
        return 0
    fi
    address=$(ip addr show dev ${name} | grep inet | grep brd | awk '{print $2}')
    gateway=$(ip route | grep 'default' | awk '{print $3}'| head -1)
    if ask "(${iname}) IPv4 Address [${address}]"; then
        address="${_RESULT}"
    fi
    if ask "(${iname}) IPv4 Gateway [${gateway}]"; then
        gateway="${_RESULT}"
    fi
    dns_servers=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | head -2)
    dns1=$(echo ${dns_servers} | awk '{print $1}')
    dns2=$(echo ${dns_servers} | awk '{print $2}')
    if ask "(${iname}) Primary DNS Server [${dns1}]"; then
        dns1="${_RESULT}"
    fi
    if ask "(${iname}) Secondary DNS Server [${dns2}] (Optional)"; then
        dns2="${_RESULT}"
    fi
    SETUP_NET+=("${name},${iname},${address},${gateway},${dns1},${dns2}")
    return 0
}

setup_init() {
    if [ $SETUP_CHECK_NET -eq 1 ]; then
        ping -c 1 google.com &> /dev/null
        if [ $? -ne 0 ]; then
            bail "No internet connection! How did you get this script?"
        fi
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
    if ask "System Hostname: [${SETUP_HOSTNAME}]"; then
        SETUP_HOSTNAME="${_RESULT}"
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
    for nic in $(ip link show | grep ': <' | awk -F':' '/,/{gsub(/ /, "", $2); print $2}' | grep -v 'lo'); do
        setup_nic "${nic}"
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
    if [[ -z "${SETUP_DRIVE}" ]] || ! [ -b "${SETUP_DRIVE}" ]; then
        while [ -z "${SETUP_DRIVE}"  ]; do
            lsblk 2> /dev/null
            if ask "Select a Disk to use"; then
                if [ -b $_RESULT ]; then
                    SETUP_DRIVE="${_RESULT}"
                fi
            fi
        done
    fi
    if [ -z "${SETUP_DRIVE}" ]; then
        bail "No drive selected!"
    fi
    return 0
}

setup_disk() {
    log "Creating partitions on \"${SETUP_DRIVE}\".."
    umount ${SETUP_DRIVE}* 2> /dev/null
    lvdisk=$(lvdisplay | grep "LV Path" | awk '{print $3}')
    if ! [ -z "${lvdisk}" ]; then
        if ! yes "Remove current LVM partitions?" 1; then
            bail "Clear disks manually, then restart!"
        fi
        for lv in $lvdisk; do
            umount "${lv}" 2> /dev/null
            lvremove --force "${lv}" 1> /dev/null 2> /dev/null
        done
        for vg in $(vgdisplay | grep "VG Name" | awk '{print $3}'); do
            vgremove --force "${vg}" 1> /dev/null 2> /dev/null
        done
        for pv in $(pvdisplay | grep "PV Name" | awk '{print $3}'); do
            pvremove --force "${pv}" 1> /dev/null 2> /dev/null
        done
        partprobe 1> /dev/null 2> /dev/null
    fi
    if [ $SETUP_EFI -eq 1 ]; then
        log "Setting up EFI disk \"${SETUP_DRIVE}\".."
        printf "g\nn\n\n\n+200M\nt\n1\nn\n\n\n\nw" | fdisk $SETUP_DRIVE
        if [ $? -ne 0 ]; then
            bail "fdisk returned a non-zero error code!"
        fi
        partprobe 1> /dev/null 2> /dev/null
        mkfs.fat -F32 -nEFI "${SETUP_DRIVE}1" 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "mkfs.fat returned a non-zero error code!"
        fi
    else
        log "Setting up MBR disk \"${SETUP_DRIVE}\".."
        printf "o\nn\n\n\n\n+200M\nt\nc\nn\n\n\n\n\nw" | fdisk $SETUP_DRIVE
        if [ $? -ne 0 ]; then
            bail "fdisk returned a non-zero error code!"
        fi
        partprobe 1> /dev/null 2> /dev/null
        mkfs.fat "${SETUP_DRIVE}1" 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "mkfs.fat returned a non-zero error code!"
        fi
    fi
    drive="${SETUP_DRIVE}2"
    if [ $SETUP_LVM -eq 1 ];then
        log "Creating LVM partitions on \"${SETUP_DRIVE}\".."
        pvcreate --force --yes "${SETUP_DRIVE}" 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "pvcreate returned a non-zero error code!"
        fi
        vgcreate --force --yes storage "${SETUP_DRIVE}" 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "vgcreate returned a non-zero error code!"
        fi
        lvcreate --yes -n root storage -l 100%FREE 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "lvcreate returned a non-zero error code!"
        fi
        log "Formatting LVM partitions on \"${SETUP_DRIVE}\".."
        drive="/dev/mapper/storage-root"
    else
        log "Formatting  partitions on \"${SETUP_DRIVE}\".."
    fi
    case $SETUP_FS in
        "xfs")
        mkfs.xfs -f -L root "${drive}" 1> /dev/null
        ;;
        "btrfs")
        mkfs.btrfs -f -L root "${drive}" 1> /dev/null
        ;;
        "ext4")
        mkfs.ext4 -F -L root "${drive}" 1> /dev/null
        ;;
        *)
        SETUP_FS="btrfs"
        mkfs.btrfs -f -L root "${drive}" 1> /dev/null
        ;;
    esac
    if [ $? -ne 0 ]; then
        bail "mkfs.${SETUP_FS} returned a non-zero error code!"
    fi
    log "Mounting Partitions.."
    if [[ $SETUP_FS == "btrfs" ]]; then
        mount -t btrfs -o compress=zstd,space_cache=v2 "${drive}" /mnt
        if [ $? -ne 0 ]; then
            bail "mount returned a non-zero error code!"
        fi
        btrfs subvolume create /mnt/base 1> /dev/null
        if [ $? -ne 0 ]; then
            bail "btrfs subvolume create returned a non-zero error code!"
        fi
        sync
        umount /mnt
        if [ $? -ne 0 ]; then
            bail "umount returned a non-zero error code!"
        fi
        sync
        mount -t btrfs -o compress=zstd,subvol=/base,space_cache=v2 "${drive}" /mnt
        if [ $? -ne 0 ]; then
            bail "mount returned a non-zero error code!"
        fi
    else
        mount "${drive}" /mnt
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
    pkgs=( "base" "net-tools" "openssh" "reflector" "linux" "linux-hardened" "man-db" "pacman-contrib" "git" "which" "vi" "nano" "diffutils" "systemd-sysvcompat" "logrotate" "linux-firmware" "less" "device-mapper")
    if [ $SETUP_LVM -eq 1 ]; then
        pkgs+=("lvm2")
    fi
    if [[ "$SETUP_FS" == "btrfs" ]]; then
        pkgs+=("btrfs-progs")
    fi
    if [[ "$SETUP_FS" == "xfs" ]]; then
        pkgs+=("xfsprogs")
    fi
    if [[ "$SETUP_FS" == "ext4" ]]; then
        pkgs+=("e2fsprogs")
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
    mkdir -p "${SETUP_DIRECTORY}/etc/udev/rules.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/network"
    mkdir -p "/mnt/etc/systemd/system/timers.target.wants"
    mkdir -p "/mnt/etc/systemd/system/sockets.target.wants"
    mkdir -p "/mnt/etc/systemd/system/sysinit.target.wants"
    mkdir -p "/mnt/etc/systemd/system/network-online.target.wants"
    for nic in ${SETUP_NET[@]}; do
        name=$(echo ${nic} | awk -F, '{print $1}')
        alias=$(echo ${nic} | awk -F, '{print $2}')
        address=$(echo ${nic} | awk -F, '{print $3}')
        gateway=$(echo ${nic} | awk -F, '{print $4}')
        dns1=$(echo ${nic} | awk -F, '{print $5}')
        dns2=$(echo ${nic} | awk -F, '{print $6}')
        log "Configuring Interface \"${name}\".."
        if ! [ -z "$alias" ]; then
            mac=$(ip link show ${name} | grep ether | awk '{print $2}')
            printf "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${alias}\"\n" >> "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            chmod 400 "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            name="${alias}"
        fi
        printf "[Match]\nName=${name}\n\n" > "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        if [ -z "${address}" ]; then
            printf "[Network]\nDHCP=yes\n\n[DHCP]\nUseDomains=yes\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        else
            printf "[Network]\nAddress=${address}\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        fi
        if ! [ -z "${dns1}" ]; then
            printf "DNS=${dns1}\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        fi
        if ! [ -z "${dns2}" ]; then
            printf "DNS=${dns2}\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        fi
        if ! [ -z "${gateway}" ]; then
            printf "\n[Route]\nGateway=${gateway}\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
        fi
        chmod 444 "${SETUP_DIRECTORY}/etc/systemd/network/${name}.network"
    done
    touch "${SETUP_DIRECTORY}/etc/vconsole.conf"
    touch "${SETUP_DIRECTORY}/etc/syscheck.d/empty.sh"
    if [ $SETUP_EFI -eq 0 ]; then
        if [ $SETUP_LVM -eq 1 ]; then
            sed -i -e 's/part_gpt part_msdos/part_gpt lvm part_msdos/g' "/mnt/etc/default/grub"
        fi
    fi
    printf 'FILES=()\nCOMPRESSION="zstd"\nCOMPRESSION_OPTIONS=(-9)\nMODULES_DECOMPRESS="yes"\nMODULES=()\nBINARIES=(' > "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    if [[ "${SETUP_FS}" == "btrfs" ]]; then
        printf 'btrfs fsck.btrfs)\nFILES=(/usr/bin/btrfs /usr/bin/fsck.btrfs)\nHOOKS=(' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    else
        printf ')\nFILES=()\nHOOKS=(' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    printf 'systemd autodetect modconf block sd-vconsole' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    if [ $SETUP_LVM -eq 1 ]; then
        printf " lvm2" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    if [[ "${SETUP_FS}" == "btrfs" ]]; then
        printf " btrfs" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    printf 'filesystems fsck)\n' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    printf "$SETUP_HOSTNAME\n" > "${SETUP_DIRECTORY}/etc/motd"
    printf "$SETUP_HOSTNAME" > "${SETUP_DIRECTORY}/etc/hostname"

    # Automatically generated build files script.
    # Args: ./build-config.py Config

    mkdir -p "${SETUP_DIRECTORY}/bin" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/iptables" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/modprobe.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/pacman.d/hooks" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/profile.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/security/limits.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/ssh" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/syscheck.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/sysctl.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d" 2> /dev/null

    # Create file "/bin/relink"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '#!/usr/bin/bash\n\nDEBUG=0\n\nif [ $# -ne 2 ]; then\n    echo "relink <config so' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'urce> <config target> [debug]"\n    exit 1\nfi\n\nif [ $# -eq 3 ]; then\n    DEB' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'UG=1\nfi\n\nlist() {\n    if [ $# -ne 2 ]; then\n        return 1\n    fi\n    f' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'c=${1%%/}\n    ft=${2%%/}\n    for file in $(find "$fc" -type f -print); do\n   ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '     fp=$(printf "$file" | awk "{gsub(\\"${fc}\\", \\"\\"); print \\$1}")\n     ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '   if ! [ -z $(echo $fp | grep -vE '\''.(nlk|nolink)$|^/.git(|ignore$|config$)|^' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '/(LICENSE|license|.vscode)$|^/[a-zA-Z0-9_.-]+.(md|vscode|MD|code-workspace)$'\''' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ') ]; then\n            check "$ft$fp" "$fc$fp"\n        fi\n    done\n    return' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' 0\n}\n\nlink() {\n    if [ $# -ne 2 ]; then\n        return 1\n    fi\n    rm -' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'f "$1" 2> /dev/null\n    fd=$(dirname "$1")\n    if ! [ -d "$fd" ]; then\n      ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '  echo "Making \\"$fd\\".."\n        mkdir -p "$fd" 2> /dev/null\n        if [ $' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '? -ne 0 ]; then\n            panic "Cannot create directory \\"$fd\\"!"\n       ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' fi\n        if [ $UID -eq 0 ]; then\n            chmod 555 "$fd"\n        else\n' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '            chmod 755 "$fd"\n        fi\n    fi\n    ln -s "$2" "$1"\n    if [ $' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '? -ne 0 ]; then\n        panic "Could not link \\"$1\\" to \\"$2\\"!"\n    fi\n ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '   echo "[+] Relinked \\"$1\\" to \\"$2\\"."\n    return 0\n}\n\ncheck() {\n    ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'if [ $# -ne 2 ]; then\n        return 1\n    fi\n    if [ $DEBUG -eq 1 ]; then\n' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '        echo "[+] Checking \\"$1\\".."\n    fi\n    if ! [ -L "$1" ]; then\n    ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '    echo "File \\"$1\\" is invalid, updating!"\n        link "$1" "$2"\n    else' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '\n        fl=$(ls -al "$1" | awk '\''{print $11}'\'')\n        if ! [[ "$fl" == ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '"$2" ]]; then\n            echo "File \\"$1\\" is invalid, updating!"\n         ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '   link "$1" "$2"\n        else\n            if [ $DEBUG -eq 1 ]; then\n        ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '        echo "File \\"$1\\" is valid!"\n            fi\n        fi\n    fi\n    ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'return 0\n}\n\npanic() {\n    echo "[!] $1"\n    exit 1\n}\n\nif ! [ -d "$1" ]; ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'then\n    panic "Config source \\"$1\\" does not exist!"\nfi\n\nif ! [ -d "$2" ]' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '; then\n    mkdir -p "$2"\n    if [ $? -ne 0 ]; then\n        panic "Could not c' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'reate target directory \\"$2\\"!"\n    fi\nfi\n\nlist "$1" "$2"\nexit 0\n' >> "${SETUP_DIRECTORY}/bin/relink"

    # Create file "/bin/syscheck"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf '#!/usr/bin/bash\n\npause() {\n    printf "Press ENTER to continue.."\n    read -' >> "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf 's\n    printf "\\n"\n}\n\nif [ $UID -ne 0 ]; then\n    echo "Only root can do th' >> "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf 'is!"\n    exit 1\nfi\n\nuname -a\npause\nsystemctl --failed\npause\nifconfig\npa' >> "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf 'use\nnetstat -panut\npause\nps xfua\npause\ndf -h\npause\nmount\npause\npacman -' >> "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf 'Syy 1> /dev/null\necho "Orphaned Packages Found:"\npacman -Qtdq\necho "Done!"\ne' >> "${SETUP_DIRECTORY}/bin/syscheck"
    /usr/bin/printf 'xit 0\n' >> "${SETUP_DIRECTORY}/bin/syscheck"

    # Create file "/bin/syslink"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'G" ]; then\n    echo "Could not find the System Configuration directory!"\n    e' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'xit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" does not exist!"\n    exit 1\nfi\n\nSYSCONFIG=${SYSCONFIG%%' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '/}\n\nif [ $UID -ne 0 ]; then\n    echo "Only root can do this!"\n    exit 1\nfi' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '\n\nrelink "$SYSCONFIG" /\n\npacman -Qeq 1> "${SYSCONFIG}/packages.md"\ncp "/etc' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '/fstab" "${SYSCONFIG}/etc/fstab.nlk"\nsystemctl list-unit-files | grep '\''maske' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'd'\''| awk '\''{print $1}'\'' 1> "${SYSCONFIG}/masked.md"\nsystemctl list-units ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '| grep '\''@.'\'' | grep -vE '\''dead|exited'\''| awk '\''{print $1}'\'' | grep ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '-vE '\''getty|user|blockdev'\'' | grep '\''@.'\'' 1> "${SYSCONFIG}/indirect.md"\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'systemctl list-unit-files | awk '\''{print $1" "$2}'\'' | grep '\''enabled'\'' |' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' grep -v '\''.target'\'' | grep -v '\''enabled-runtime'\'' | awk '\''{print $1}'\''' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' 1> "${SYSCONFIG}/units.md"\n\nchown -R root:root "$SYSCONFIG"\nchmod -R 555 "$S' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'YSCONFIG"\n\nfind "$SYSCONFIG" -type f -exec chmod 444 {} \\;\nfind "$SYSCONFIG"' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' -type d -exec chmod 555 {} \\;\n\nchmod -R 555 "${SYSCONFIG}/bin"\nchmod -R 555' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' "${SYSCONFIG}/etc/profile.d"\nchmod -R 500 "${SYSCONFIG}/etc/syscheck.d"\n\nchm' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'od 555 "${SYSCONFIG}/etc/ssh"\nchmod 500 "${SYSCONFIG}/etc/sysctl.d"\nchmod 500 ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '"${SYSCONFIG}/etc/security"\nchmod 500 "${SYSCONFIG}/etc/iptables"\nchmod 500 "$' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '{SYSCONFIG}/etc/modprobe.d"\nchmod 500 "${SYSCONFIG}/etc/pacman.d/hooks"\nchmod ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '400 "${SYSCONFIG}/etc/mkinitcpio.conf"\nchmod 440 "${SYSCONFIG}/etc/ssh/sshd_con' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'fig"\nchmod 500 "${SYSCONFIG}/etc/security/limits.d"\nchmod 400 "${SYSCONFIG}/et' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'c/sysctl.d/kernel.conf"\nchmod 400 "${SYSCONFIG}/etc/systemd/coredump.conf"\nchm' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'od 400 "${SYSCONFIG}/etc/iptables/iptables.rules"\nchmod 400 "${SYSCONFIG}/etc/i' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'ptables/ip6tables.rules"\nchmod 400 "${SYSCONFIG}/etc/security/limits.d/limits.c' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'onf"\n\nchmod 400 ${SYSCONFIG}/etc/modprobe.d/*\nchmod 400 ${SYSCONFIG}/etc/pacm' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'an.d/hooks/*\n\nchmod 400 /etc/iptables/*\nchmod 400 /etc/pacman.d/hooks/*\n\nch' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'mod -R 555 "/etc/profile.d"\nchmod -R 500 "/etc/syscheck.d"\n\nchmod 555 "/etc/s' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'sh"\nchmod 555 "/etc/systemd"\nchmod 500 "/etc/sysctl.d"\nchmod 500 "/etc/iptabl' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'es"\nchmod 500 "/etc/security"\nchmod 500 "/etc/modprobe.d"\nchmod 500 "/etc/pac' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'man.d/hooks"\nchmod 500 "/etc/security/limits.d"\n\nchmod 444 "/etc/motd"\nchmod' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' 444 "/etc/hosts"\nchmod 550 "/etc/pacman.d"\nchmod 444 "/etc/hostname"\nchmod 4' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '44 "/etc/locale.gen"\nchmod 444 "/etc/resolv.conf"\nchmod 400 "/etc/pacman.conf"' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '\nchmod 444 "/etc/nsswitch.conf"\nchmod 400 "/etc/vconsole.conf"\nchmod 444 "/et' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'c/sysconfig.conf"\nchmod 444 "/etc/ssh/ssh_config"\nchmod 400 "/etc/mkinitcpio.c' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'onf"\n\nchown root:root -R "/etc/systemd"\nchown root:root -R "/etc/iptables"\nc' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'hown root:root -R "/etc/pacman.d"\nchown root:root -R "/etc/security"\nchown roo' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 't:root -R "/etc/sysctl.d"\nchown root:root -R "/etc/profile.d"\nchown root:root ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '-R "/etc/modprobe.d"\nchown root:root -R "/etc/syscheck.d"\n\nchown root:root "/' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'etc/motd"\nchown root:root "/etc/hosts"\nchown root:root "/etc/hostname"\nchown ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'root:root "/etc/locale.gen"\nchown root:root "/etc/resolv.conf"\nchown root:root' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' "/etc/pacman.conf"\nchown root:root "/etc/vconsole.conf"\nchown root:root "/etc' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '/nsswitch.conf"\nchown root:root "/etc/sysconfig.conf"\nchown root:root "/etc/mk' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'initcpio.conf"\n\nfind "/etc/ssh" -type f -exec chmod 400 {} \\;\nfind "/etc/sys' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'temd" -type f -exec chmod 444 {} \\;\nfind "/etc/pacman.d" -type f -exec chmod 4' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '40 {} \\;\nfind "/etc/sysctl.d" -type f -exec chmod 440 {} \\;\nfind "/etc/secur' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'ity" -type f -exec chmod 440 {} \\;\nfind "/etc/modprobe.d" -type f -exec chmod ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '440 {} \\;\nfind "/etc/systemd/network" -type f -exec chmod 444 {} \\;\n\nif [ -' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'd "/etc/syscheck.d" ]; then\n    for s in $(ls /etc/syscheck.d/*.sh); do\n      ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '  source "$s"\n    done\nfi\n\necho "Broken Links Found:"\nfind /etc -xtype l 2>' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' /dev/null | grep -v "/proc" | grep -v "/tmp" | grep -v "/run"\necho "Done!"\nex' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'it 0\n' >> "${SETUP_DIRECTORY}/bin/syslink"

    # Create file "/bin/syspull"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'G" ]; then\n    echo "Could not find the System Configuration directory!"\n    e' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'xit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" does not exist!"\n    exit 1\nfi\n\nSYSCONFIG=${SYSCONFIG%%' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" is not a Git repository!"\n    exit 1\nfi\n\nif [ $UID -ne ' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '0 ]; then\n    echo "Only root can do this!"\n    exit 1\nfi\n\nsh -c "cd ${SYSC' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'ONFIG}; git pull"\nsyslink\n' >> "${SETUP_DIRECTORY}/bin/syspull"

    # Create file "/bin/syspush"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'G" ]; then\n    echo "Could not find the System Configuration directory!"\n    e' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'xit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" does not exist!"\n    exit 1\nfi\n\nSYSCONFIG=${SYSCONFIG%%' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" is not a Git repository!"\n    exit 1\nfi\n\nif [ $UID -ne ' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '0 ]; then\n    echo "Only root can do this!"\n    exit 1\nfi\n\nsh -c "cd ${SYSC' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'ONFIG}; git add -A .; git commit -m '\''syspush'\''; git push"\nsyslink\n' >> "${SETUP_DIRECTORY}/bin/syspush"

    # Create file "/bin/sysupdate"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '#!/usr/bin/bash\n\nif [ $UID -ne 0 ]; then\n    echo "Only root can do this!"\n ' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '   exit 1\nfi\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFIG"' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf ' ]; then\n    echo "Could not find the System Configuration directory!"\n    exi' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 't 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    echo "System Configuration director' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'y \\"$SYSCONFIG\\" does not exist!"\n    exit 1\nfi\n\nif [ "$1" == "--auto" ]; ' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'then\n    if [ "$2" == "--download" ]; then\n        pacman -Syuw --noconfirm\n ' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '       exit 0\n    fi\n    pacman -Syu --noconfirm\nelse\n    pacman -Syu\nfi\n\n' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'syslink\nsh -c "cd ${SYSCONFIG}; git status -s"\n' >> "${SETUP_DIRECTORY}/bin/sysupdate"

    # Create file "/etc/iptables/ip6tables.rules"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT DROP [0:0]\n:BASE - [' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '0:0]\n-A INPUT -j BASE\n-A OUTPUT -j BASE\n-A BASE -i lo -j ACCEPT\n-A BASE -s :' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf ':1/128 -d ::1/128 -j ACCEPT\n-A BASE -m state --state INVALID -j DROP\n-A BASE -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'p tcp -m state --state RELATED,ESTABLISHED -j ACCEPT\n-A BASE -p udp -m state --' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'state RELATED,ESTABLISHED -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf ' 1 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 2 -j ACCEPT\n-A BASE -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'p ipv6-icmp -m icmp6 --icmpv6-type 3 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'icmpv6-type 4 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 133 -j ACCE' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'PT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 134 -j ACCEPT\n-A BASE -p ipv6-i' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'cmp -m icmp6 --icmpv6-type 135 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-type 136 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 137 -j ACCEPT\n' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 141 -j ACCEPT\n-A BASE -p ipv6-icmp ' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-m icmp6 --icmpv6-type 142 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-typ' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'e 148 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 149 -j ACCEPT\n-A B' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'ASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 130 -j ACCEPT\n-A BASE -s f' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'e80::/10 -p ipv6-icmp -m icmp6 --icmpv6-type 131 -j ACCEPT\n-A BASE -s fe80::/10' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf ' -p ipv6-icmp -m icmp6 --icmpv6-type 132 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-icmp -m icmp6 --icmpv6-type 143 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf ' icmp6 --icmpv6-type 151 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-icmpv6-type 152 -j ACCEPT\n-A BASE -s fe80::/10 -p ipv6-icmp -m icmp6 --icmpv6-' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'type 153 -j ACCEPT\n-A BASE -p ipv6-icmp -m icmp6 --icmpv6-type 129 -m limit --l' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'imit 1/sec -j ACCEPT\n-A BASE -m icmp6 -p ipv6-icmp --icmpv6-type 128 -m limit -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-limit 1/sec -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 53 -j ACCEPT\n-A OUTPUT ' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '-m udp -p udp --dport 53 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 80 -j ACCEPT' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '\n-A OUTPUT -m udp -p udp --dport 80 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport ' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf '443 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 443 -j ACCEPT\n-A OUTPUT -m udp -' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf 'p udp --dport 123 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 11371 -j ACCEPT\n-A' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"
    /usr/bin/printf ' OUTPUT -m udp -p udp --dport 546:547 -j ACCEPT\nCOMMIT\n' >> "${SETUP_DIRECTORY}/etc/iptables/ip6tables.rules"

    # Create file "/etc/iptables/iptables.rules"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT DROP [0:0]\n:BASE - [' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '0:0]\n-A INPUT -j BASE\n-A OUTPUT -j BASE\n-A BASE -i lo -j ACCEPT\n-A BASE -s 1' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '27.0.0.1/32 -d 127.0.0.1/32 -j ACCEPT\n-A BASE -p icmp -m icmp --icmp-type 3 -j ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'ACCEPT\n-A BASE -p icmp -m icmp --icmp-type 3/1 -j ACCEPT\n-A BASE -p icmp -m ic' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'mp --icmp-type 0 -m limit --limit 1/sec -j ACCEPT\n-A BASE -p icmp -m icmp --icm' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'p-type 8 -m limit --limit 1/sec -j ACCEPT\n-A BASE -f -j DROP\n-A BASE -d 0.0.0.' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '0/32 -j DROP\n-A BASE -s 224.0.0.0/8 -j DROP\n-A BASE -d 224.0.0.0/8 -j DROP\n-A' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf ' BASE -d 255.255.255.255/32 -j DROP\n-A BASE -s 255.255.255.255/32 -j DROP\n-A B' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'ASE -m state --state INVALID -j DROP\n-A BASE -f -m limit --limit 10/min -j ACCE' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'PT\n-A BASE -m addrtype --dst-type ANYCAST -j DROP\n-A BASE -m addrtype --dst-ty' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'pe BROADCAST -j DROP\n-A BASE -m addrtype --dst-type MULTICAST -j DROP\n-A BASE ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '-p tcp -m state --state RELATED,ESTABLISHED -j ACCEPT\n-A BASE -p udp -m state -' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf '-state RELATED,ESTABLISHED -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 53 -j ACCE' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'PT\n-A OUTPUT -m udp -p udp --dport 53 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dpor' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 't 80 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 80 -j ACCEPT\n-A OUTPUT -m tcp -' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'p tcp --dport 443 -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 443 -j ACCEPT\n-A O' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'UTPUT -m udp -p udp --dport 123 -j ACCEPT\n-A OUTPUT -m tcp -p tcp --dport 11371' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf ' -j ACCEPT\n-A OUTPUT -m udp -p udp --dport 67:68 -j ACCEPT\n-A INPUT -m tcp -p ' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"
    /usr/bin/printf 'tcp --dport 22 -j ACCEPT\nCOMMIT\n' >> "${SETUP_DIRECTORY}/etc/iptables/iptables.rules"

    # Create file "/etc/locale.gen"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/locale.gen"
    /usr/bin/printf 'en_US.UTF-8 UTF-8\nen_US       ISO-8859-1\n' >> "${SETUP_DIRECTORY}/etc/locale.gen"

    # Create file "/etc/modprobe.d/pcspkr.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"
    /usr/bin/printf 'blacklist pcspkr\n' >> "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"

    # Create file "/etc/nsswitch.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'passwd:     files systemd\ngroup:      files systemd\nshadow:     files systemd\n' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'gshadow:    files systemd\n\npublickey:  files\n\nhosts:      files mymachines m' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'yhostname resolve dns\nnetworks:   files\n\nprotocols:  files\nservices:   files' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf '\nethers:     files\nrpc:        files\n\nnetgroup:   files\n' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"

    # Create file "/etc/pacman.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '[options]\nDBPath              = /var/lib/pacman\nGPGDir              = /etc/pac' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'man.d/gnupg\nRootDir             = /\nHookDir             = /etc/pacman.d/hooks\n' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'LogFile             = /var/log/pacman.log\nHoldPkg             = pacman glibc\nC' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'acheDir            = /var/cache/pacman/pkg\nSigLevel            = Required Datab' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'aseOptional\nCleanMethod         = KeepInstalled\nArchitecture        = auto\nPa' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'rallelDownloads   = 5\nLocalFileSigLevel   = Optional\n\nCheckSpace\nVerbosePkgL' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'ists\n\n[core]\nInclude             = /etc/pacman.d/mirrorlist\n[extra]\nInclude' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '             = /etc/pacman.d/mirrorlist\n[community]\nInclude             = /etc' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '/pacman.d/mirrorlist\n' >> "${SETUP_DIRECTORY}/etc/pacman.conf"

    # Create file "/etc/pacman.d/hooks/findorphans.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    /usr/bin/printf 'n/bash -c "pacman -Qtdq || echo '\''No orphans found.'\''"\nDescription = Findin' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"
    /usr/bin/printf 'g orphan packages..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findorphans.hook"

    # Create file "/etc/pacman.d/hooks/findpac.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"
    /usr/bin/printf 'n/find /etc -type f -name *.pac* -ls\nDescription = Looking for *.pac* files..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/findpac.hook"

    # Create file "/etc/pacman.d/hooks/fixperms.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    /usr/bin/printf 'on   = Upgrade\nOperation   = Install\n\n[Action]\nWhen        = PostTransaction' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    /usr/bin/printf '\nExec        = /usr/bin/syslink\nDescription = Fixing permissions for system fi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"
    /usr/bin/printf 'les..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/fixperms.hook"

    # Create file "/etc/pacman.d/hooks/iptables.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = iptables\nOperation   = Upgrade\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    /usr/bin/printf '\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bin/rm /etc/iptabl' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    /usr/bin/printf 'es/simple_firewall.rules /etc/iptables/empty.rules\nDescription = Removing simpl' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"
    /usr/bin/printf 'e rules files..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/iptables.hook"

    # Create file "/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = pacman-mirrorlist\nOperation   =' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf ' Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bin/bash' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf ' -c "reflector --protocol https --latest 30 --number 20 --sort rate --country '\''' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf 'United States'\'' --save /etc/pacman.d/mirrorlist; rm -f /etc/pacman.d/mirrorlis' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf 't.pacnew 2> /dev/null"\nDepends     = reflector\nDescription = Updating pacman-m' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"
    /usr/bin/printf 'irrorlist with reflector and removing pacnew..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/mirrorupgrade.hook"

    # Create file "/etc/pacman.d/hooks/paccache.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    /usr/bin/printf 'n/bash -c "paccache -rk2; paccache -ruk0"\nDescription = Removing old cached pac' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"
    /usr/bin/printf 'kages..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/paccache.hook"

    # Create file "/etc/profile.d/alias.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nalias nano="nano -SLlwxiE --tabsize=4"\n' >> "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"

    # Create file "/etc/profile.d/history.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/history.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nHISTSIZE=500\nHISTFILESIZE=0\nHISTFILE=/dev/null\n' >> "${SETUP_DIRECTORY}/etc/profile.d/history.sh"

    # Create file "/etc/profile.d/umask.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\numask 027\n' >> "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"

    # Create file "/etc/profile.d/z_system_status.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nstatus_repo() {\n    source "/etc/sysconfig.conf" 2> /dev/nul' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'l\n    if [ $? -ne 0 ]; then\n        return 0\n    fi\n    if [ -z "$SYSCONFIG"' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' ]; then\n        return 0\n    fi\n    if ! [ -d "$SYSCONFIG" ]; then\n        ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'return 0\n    fi\n    SYSCONFIG=${SYSCONFIG%%/}\n    if ! [ -d "${SYSCONFIG}/.gi' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 't" ]; then\n        return 0\n    fi\n    if ! [[ -z $(bash -c "cd ${SYSCONFIG};' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' git status | grep -iE '\''modified|deleted|Untracked'\''") ]]; then\n        pr' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'intf '\''# Config:\\tSync needed, use "syspush"\\n'\''\n    else\n        printf' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' "# Config:\\tUp-to-Date\\n"\n    fi\n}\nstatus_storage() {\n    printf "# Stora' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'ge:\\n"\n    df -h | grep -v "tmpfs" | grep -E '\''/dev/|/opt/|/mnt/'\'' | sort ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '-r | awk '\''{print ""$1" "$5" ("$3"/"$2")"}'\'' | column -t | awk '\''{print "#' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '     "$0}'\''\n}\nstatus_network() {\n    printf "# Interface Addresses:\\n"\n  ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '  for i in $(ip addr |grep '\''inet'\'' | grep -vE '\''::1|127.0.0.1|link'\'' | ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'awk '\''{print $2}'\'' | awk -F'\''/'\'' '\''{print $1}'\''); do\n        printf' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' "#     $i\\n"\n    done\n}\nstatus_services() {\n    nl=$(netstat -panut 2>/dev' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '/null | grep LISTEN | wc -l)\n    ne=$(netstat -panut 2>/dev/null | grep ESTABLI' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'SHED | wc -l)\n    printf "# Network:\\t$ne Established, $nl Listening\\n"\n    ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'st=$(systemctl --all --no-legend --no-pager | grep ".timer" | wc -l)\n    sf=$(s' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'ystemctl --state=failed --no-legend --no-pager | grep ".service" | wc -l)\n    s' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'a=$(systemctl --state=active --no-legend --no-pager | grep ".service" | grep "ru' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'nning" | wc -l)\n    printf "# Services:\\t$sa Running, $sf Failed, $st Timers\\' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'n"\n}\n\nif [[ $- != *i* ]] || [ ! -z "$SSH_CLIENT" ]; then\n    printf "#######' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '#######################################################\\n"\n    status_storage\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '    status_network\n    printf "# Uptime:\\t$(uptime --pretty | sed '\''s/up //g' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ''\'')\\n"\n    printf "# Kernel:\\t$(uname -r)\\n"\n    status_repo\n    status_' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'services\n    printf "##########################################################' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '####\\n"\nfi\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"

    # Create file "/etc/security/limits.d/limits.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/security/limits.d/limits.conf"
    /usr/bin/printf '* hard core 0\n* soft nproc 2500\n* hard nproc 5000\n' >> "${SETUP_DIRECTORY}/etc/security/limits.d/limits.conf"

    # Create file "/etc/ssh/ssh_config"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'Host *\n    Port                            22\n    MACs                        ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '    hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@ope' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'nssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com\n    Tunnel           ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '               no\n    Ciphers                         chacha20-poly1305@openssh' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'ctr\n    Protocol                        2\n    BatchMode                       ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'no\n    ForwardX11                      no\n    CheckHostIP                     ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'yes\n    IdentityFile                    ~/.ssh/id_rsa\n    IdentityFile        ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '            ~/.ssh/id_ed25519\n    ForwardAgent                    no\n    KexAl' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'gorithms                   curve25519-sha256@libssh.org,diffie-hellman-group-exc' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'hange-sha256\n    VisualHostKey                   yes\n    AddressFamily        ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '           any\n    ConnectTimeout                  30\n    HashKnownHosts      ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '            yes\n    HostKeyAlgorithms               ssh-ed25519-cert-v01@openss' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'h.com,ssh-rsa-cert-v01@openssh.com,ssh-ed25519,ssh-rsa\n    PermitLocalCommand  ' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '            no\n    GSSAPIAuthentication            no\n    PubkeyAuthentication' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf '            yes\n    StrictHostKeyChecking           ask\n    PasswordAuthentica' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'tion          no\n    HostbasedAuthentication         no\n    GSSAPIDelegateCred' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'entials       no\n    ChallengeResponseAuthentication yes\n' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"

    # Create file "/etc/ssh/sshd_config"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'Port                            22\nMACs                            hmac-sha2-51' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '2-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sh' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'a2-512,hmac-sha2-256,umac-128@openssh.com\nUsePAM                          yes\n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'Ciphers                         chacha20-poly1305@openssh.com,aes256-gcm@openssh' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr\nHostKey           ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '              /etc/ssh/ssh_host_rsa_key\nHostKey                         /etc/ss' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'h/ssh_host_ed25519_key\nProtocol                        2\nSubsystem            ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '           sftp /usr/lib/ssh/sftp-server\nPrintMotd                       no\nPe' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'rmitTTY                       yes\nCompression                     no\nMaxStartu' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'ps                     10:30:100\nGatewayPorts                    no\nPermitTunn' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'el                    no\nPrintLastLog                    yes\nIgnoreRhosts     ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '               yes\nTCPKeepAlive                    yes\nAddressFamily          ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '         any\nListenAddress                   0.0.0.0\nKexAlgorithms            ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '       curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256\nLoginG' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'raceTime                  1m\nPermitRootLogin                 yes\nAllowTcpForwa' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'rding              no\nAuthorizedKeysFile              .ssh/authorized_keys\nCli' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'entAliveCountMax             0\nClientAliveInterval             600\nIgnoreUserK' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'nownHosts            no\nPermitEmptyPasswords            no\nAllowAgentForwardin' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'g            no\nPubkeyAuthentication            yes\nPasswordAuthentication    ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '      no\nKerberosAuthentication          no\nHostbasedAuthentication         no' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '\nChallengeResponseAuthentication no\n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"

    # Create file "/etc/syscheck.d/git.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf 'G" ]; then\n    echo "Could not find the System Configuration directory!"\n    e' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf 'xit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    echo "System Configuration direct' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf 'ory \\"$SYSCONFIG\\" does not exist!"\n    exit 1\nfi\n\nif [ -d "${SYSCONFIG}/.' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf 'git" ]; then\n    chmod 750 $SYSCONFIG/.git/hooks/*\n    bash -c "cd ${SYSCONFIG' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"
    /usr/bin/printf '}; git status" 2> /dev/null 1> /dev/null\nfi\n' >> "${SETUP_DIRECTORY}/etc/syscheck.d/git.sh"

    # Create file "/etc/sysctl.d/kernel.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'fs.file-max                     = 372925\nvm.swappiness                   = 10\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'fs.suid_dumpable                = 0\nfs.protected_fifos              = 1\nfs.pro' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'tected_regular            = 1\nkernel.kptr_restrict            = 2\nkernel.dmesg' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf '_restrict           = 1\nfs.protected_symlinks           = 1\nfs.protected_hardl' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'inks          = 1\nkernel.yama.ptrace_scope        = 3\nfs.inotify.max_user_watc' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'hes     = 16777215\nfs.inotify.max_queued_events    = 32767\nvm.dirty_writeback_' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'centisecs    = 1500\nfs.inotify.max_user_instances   = 4096\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"

    # Create file "/etc/sysctl.d/network.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'net.core.rmem_max                           = 16777216\nnet.ipv4.tcp_rmem       ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '                    = 4096 1048576 2097152\nnet.ipv4.tcp_wmem                   ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '        = 4096 65536 16777216\nnet.core.wmem_max                           = 167' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '77216\nnet.core.somaxconn                          = 32768\nnet.core.optmem_max ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '                        = 65536\nnet.ipv4.tcp_rfc1337                        = 1' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '\nnet.ipv4.udp_rmem_min                       = 8192\nnet.ipv4.udp_wmem_min     ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '                  = 8192\nnet.core.rmem_default                       = 1048576\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'net.core.wmem_default                       = 1048576\nnet.ipv4.tcp_fastopen    ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '                   = 1\nnet.ipv4.tcp_tw_reuse                       = 1\nnet.cor' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'e.netdev_budget                      = 50000\nnet.ipv4.tcp_timestamps           ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '          = 1\nnet.core.bpf_jit_harden                     = 2\nnet.ipv4.tcp_syn' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'cookies                     = 1\nnet.ipv4.tcp_low_latency                    = 1' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '\nnet.ipv4.tcp_fin_timeout                    = 10\nnet.ipv4.tcp_keepalive_time ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '                = 600\nnet.core.netdev_max_backlog                 = 65535\nnet.' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'ipv4.tcp_max_tw_buckets                 = 2097151\nnet.ipv4.conf.all.rp_filter  ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '               = 2\nnet.core.netdev_budget_usecs                = 5000\nnet.ipv4' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '.tcp_max_syn_backlog                = 65535\nnet.ipv4.ip_local_port_range       ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '         = 1024 65535\nnet.ipv4.tcp_keepalive_intvl                = 30\nnet.ipv' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '4.tcp_keepalive_probes               = 6\nnet.ipv4.conf.default.rp_filter       ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '      = 2\nnet.ipv4.conf.all.send_redirects            = 0\nnet.ipv6.conf.all.ac' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'cept_redirects          = 0\nnet.ipv4.conf.all.accept_redirects          = 0\nne' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 't.ipv4.tcp_slow_start_after_idle          = 0\nnet.ipv4.icmp_echo_ignore_broadca' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'sts        = 1\nnet.ipv4.conf.default.send_redirects        = 0\nnet.ipv4.conf.d' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'efault.accept_redirects      = 0\nnet.ipv6.conf.default.accept_redirects      = ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '0\nnet.ipv4.icmp_ignore_bogus_error_responses  = 1\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"

    # Create file "/etc/systemd/coredump.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"
    /usr/bin/printf '[Coredump]\nStorage = none\n' >> "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"

    # Create file "/etc/systemd/homed.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/homed.conf"
    /usr/bin/printf '[Home]\nDefaultStorage          = directory\nDefaultFileSystemType   = btrfs\n' >> "${SETUP_DIRECTORY}/etc/systemd/homed.conf"

    # Create file "/etc/systemd/journald.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf '[Journal]\nAudit               = on\nStorage             = persistent\nReadKMsg ' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf '           = yes\nCompress            = yes\nSplitMode           = uid\nMaxFileS' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf 'ec          = 1day\nSystemMaxUse        = 256M\nMaxLevelStore       = info\nForw' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf 'ardToSyslog     = no\nMaxRetentionSec     = 14day\nSystemMaxFileSize   = 32M\n' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"

    # Create file "/etc/systemd/logind.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '[Login]\nNAutoVTs                        = 2\nReserveVT                       = ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '5\nRemoveIPC                       = yes\nIdleAction                      = igno' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf 're\nSessionsMax                     = 8192\nInhibitorsMax                   = 81' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '92\nHandlePowerKey                  = poweroff\nHandleLidSwitch                 ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '= ignore\nHandleRebootKey                 = reboot\nUserStopDelaySec            ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '    = 10\nHandleSuspendKey                = suspend\nKillExcludeUsers           ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '     = root\nKillUserProcesses               = yes\nHoldoffTimeoutSec           ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '    = 10s\nInhibitDelayMaxSec              = 5s\nHandleHibernateKey             ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf ' = hibernate\nRuntimeDirectorySize            = 10%%\nHandleLidSwitchDocked     ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '      = ignore\nPowerKeyIgnoreInhibited         = no\nHandleRebootKeyLongPress  ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '      = poweroff\nRebootKeyIgnoreInhibited        = no\nLidSwitchIgnoreInhibited' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '        = no\nSuspendKeyIgnoreInhibited       = no\nHibernateKeyIgnoreInhibited ' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"
    /usr/bin/printf '    = no\nHandleLidSwitchExternalPower    = ignore\n' >> "${SETUP_DIRECTORY}/etc/systemd/logind.conf"

    # Create file "/etc/systemd/networkd.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/networkd.conf"
    /usr/bin/printf '[Network]\nSpeedMeter          = no\nManageForeignRoutes = yes\n\n[DHCP]\nDUIDTy' >> "${SETUP_DIRECTORY}/etc/systemd/networkd.conf"
    /usr/bin/printf 'pe            = vendor\n' >> "${SETUP_DIRECTORY}/etc/systemd/networkd.conf"

    # Create file "/etc/systemd/pstore.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/pstore.conf"
    /usr/bin/printf '[PStore]\nStorage = none\n' >> "${SETUP_DIRECTORY}/etc/systemd/pstore.conf"

    # Create file "/etc/systemd/resolved.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf '[Resolve]\nCache                       = yes\nLLMNR                       = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'DNSSEC                      = allow-downgrade\nDNSOverTLS                  = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'FallbackDNS                 = 127.0.0.1\nReadEtcHosts                = yes\nMult' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'icastDNS                = no\nDNSStubListener             = no\nResolveUnicastSi' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'ngleLabel   = no' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"

    # Create file "/etc/systemd/system.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '[Manager]\nLogTime                         = no\nLogColor                       ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf ' = yes\nDumpCore                        = no\nLogLevel                        = ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'warning\nLogTarget                       = journal-or-kmsg\nShowStatus          ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '            = auto\nNUMAPolicy                      = default\nCrashShell       ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '               = no\nCrashReboot                     = no\nLogLocation          ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '           = no\nCrashChangeVT                   = no\nNoNewPrivileges          ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '       = no\nDefaultTasksMax                 = 15%%\nDefaultOOMPolicy           ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '     = stop\nStatusUnitFormat                = description\nKExecWatchdogSec    ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '            = off\nDefaultRestartSec               = 100ms\nDefaultLimitNOFILE  ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '            = 1024:524288\nRuntimeWatchdogSec              = 0\nShutdownWatchdog' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'Sec             = 0\nDefaultIOAccounting             = no\nDefaultIPAccounting  ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '           = no\nDefaultStandardError            = inherit\nDefaultCPUAccounting' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '            = no\nDefaultTimeoutStopSec           = 30s\nDefaultStandardOutput  ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '         = journal\nCtrlAltDelBurstAction           = reboot-force\nDefaultTimeo' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'utStartSec          = 30s\nDefaultStartLimitBurst          = 5\nDefaultTasksAcco' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'unting          = yes\nDefaultTimerAccuracySec         = 1min\nDefaultMemoryAcco' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'unting         = yes\nDefaultBlockIOAccounting        = no\nDefaultStartLimitInt' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'ervalSec    = 10s\n' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"

    # Create file "/etc/systemd/system/reflector.service"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '[Unit]\nAfter                   = network-online.target systemd-resolved.service' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '\nRequires                = network-online.target systemd-resolved.service\nDesc' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'ription             = Pacman Mirrorlist Update Service\n\n[Service]\nType       ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '             = simple\nExecStart               = /usr/bin/reflector --protocol h' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'ttps --latest 30 --number 20 --sort rate --country '\''United States'\'' --save ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '/etc/pacman.d/mirrorlist\nPrivateTmp              = true\nKeyringMode           ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '  = private\nProtectHome             = false\nProtectClock            = true\nPr' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'ivateUsers            = true\nProtectSystem           = strict\nReadWritePaths  ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '        = /etc/pacman.d /root/.cache\nPrivateDevices          = true\nNoNewPrivi' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'leges         = true\nLockPersonality         = true\nRestrictRealtime        = ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'true\nRestrictSUIDSGID        = true\nProtectKernelLogs       = true\nRestrictNa' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'mespaces      = true\nProtectControlGroups    = true\nProtectKernelModules    = ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'true\nProtectKernelTunables   = true\nRestrictAddressFamilies = AF_INET AF_INET6' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '\n\n[Install]\nRequiredBy              = multi-user.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"

    # Create file "/etc/systemd/system/reflector.timer"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf '[Unit]\nDescription         = Pacman Mirrorlist Update Timer\n\n[Timer]\nOnCalen' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf 'dar          = weekly\nPersistent          = true\nRandomizedDelaySec  = 12h\n\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf '[Install]\nWantedBy            = timers.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"

    # Create file "/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"
    /usr/bin/printf '[Service]\nExecStart =\nExecStart = -/usr/bin/archlinux-keyring-wkd-sync\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"

    # Create file "/etc/systemd/timesyncd.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    /usr/bin/printf '[Time]\nNTP                 = time.nist.gov time-a-g.nist.gov time-b-g.nist.gov\n' >> "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    /usr/bin/printf 'RootDistanceMaxSec  = 30\n' >> "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"

    # Create file "/etc/systemd/sleep.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"
    /usr/bin/printf '[Sleep]\nAllowSuspend                = no\nAllowHibernation            = no\nAll' >> "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"
    /usr/bin/printf 'owHybridSleep            = no\nAllowSuspendThenHibernate   = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"

    # Create file "/etc/vconsole.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/vconsole.conf"
    /usr/bin/printf 'KEYMAP=us\n' >> "${SETUP_DIRECTORY}/etc/vconsole.conf"

    # Create file "/etc/locale.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf 'LANG=en_US.UTF-8\nLC_TIME="en_US.UTF-8"\nLC_NAME="en_US.UTF-8"\nLC_CTYPE="en_US.' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf 'UTF-8"\nLC_PAPER="en_US.UTF-8"\nLC_NUMERIC="en_US.UTF-8"\nLC_COLLATE="en_US.UTF-' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '8"\nLC_ADDRESS="en_US.UTF-8"\nLC_MONETARY="en_US.UTF-8"\nLC_MESSAGES="en_US.UTF-' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '8"\nLC_TELEPHONE="en_US.UTF-8"\nLC_MEASUREMENT="en_US.UTF-8"\nLC_IDENTIFICATION=' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '"en_US.UTF-8"\n' >> "${SETUP_DIRECTORY}/etc/locale.conf"

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
    chmod 555 "/mnt/etc/systemd/system/timers.target.wants"
    chmod 555 "/mnt/etc/systemd/system/sockets.target.wants"
    chmod 555 "/mnt/etc/systemd/system/sysinit.target.wants"
    chmod 555 "/mnt/etc/systemd/system/network-online.target.wants"
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
    rm -f "/mnt/etc/localtime" 2> /dev/null
    rm -f "/mnt/etc/resolv.conf" 2> /dev/null
    rm -f "/mnt/etc/iptables/empty.rules" 2> /dev/null
    rm -f "/mnt/etc/iptables/simple_firewall.rules" 2> /dev/null
    awk '$5 > 2000' "/mnt/etc/ssh/moduli" > "/mnt/etc/ssh/moduli"
    ssh-keygen -t ed25519 -f "/mnt/etc/ssh/ssh_host_ed25519_key" -N "" < /dev/null > /dev/null
    ssh-keygen -t rsa -b 4096 -f "/mnt/etc/ssh/ssh_host_rsa_key" -N "" < /dev/null > /dev/null
    log "System configuration complete.."
    return 0
}

setup_chroot() {
    log "Building chroot.."
    mkdir /mnt/tmplvm
    mount --bind /run/lvm /mnt/tmplvm
    printf '#!/bin/bash\n\n' > "/mnt/root/start.sh"
    printf 'ln -s /tmplvm /run/lvm\n' >> "/mnt/root/start.sh"
    printf 'vgscan -v 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf "bash ${SETUP_CONFIGURATION}/bin/relink ${SETUP_CONFIGURATION} /\n" >> "/mnt/root/start.sh"
    printf "bash ${SETUP_CONFIGURATION}/bin/syslink\n" >> "/mnt/root/start.sh"
    printf 'locale-gen\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/share/zoneinfo/America/New_York /etc/localtime\n' >> "/mnt/root/start.sh"
    printf 'mkinitcpio -p linux-hardened\n' >> "/mnt/root/start.sh"
    printf 'mkinitcpio -p linux\n' >> "/mnt/root/start.sh"
    printf 'printf "archlinux\\narchlinux" | passwd root\n' >> "/mnt/root/start.sh"
    if [ $SETUP_EFI -eq 1 ]; then
        printf "bootctl install\n" >> "/mnt/root/start.sh"
    else
        printf "grub-install ${SETUP_DRIVE}\n" >> "/mnt/root/start.sh"
        printf "grub-mkconfig -o /boot/grub/grub.cfg\n" >> "/mnt/root/start.sh"
        printf "grub-set-default 1\n" >> "/mnt/root/start.sh"
    fi
    printf "touch /run/systemd/resolve/resolv.conf &> /dev/null\n" >> "/mnt/root/start.sh"
    printf "ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf\n" >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/fstrim.timer /etc/systemd/system/timers.target.wants/fstrim.timer\n' >> "/mnt/root/start.sh"
    printf 'ln -s /etc/systemd/system/reflector.timer /etc/systemd/system/timers.target.wants/reflector.timer\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /etc/systemd/system/checkupdates.timer /etc/systemd/system/timers.target.wants/checkupdates.timer\n' >> "/mnt/root/start.sh"
    printf 'ln -s /etc/systemd/system/reflector.service /etc/systemd/system/multi-user.target.wants/reflector.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /etc/systemd/system/checkupdates.service /etc/systemd/system/multi-user.target.wants/checkupdates.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /usr/lib/systemd/system/systemd-networkd-wait-online.service /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/emergency.target 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/emergency.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/var-lib-machines.mount 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/debug-shell.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/rescue.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-firstboot.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-homed.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-hwdb-update.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-pstore.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-repart.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/systemd-sysusers.service 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'rm /etc/systemd/system/first-boot-complete.target 2> /dev/null\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/emergency.target\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/emergency.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/var-lib-machines.mount\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/debug-shell.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/rescue.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-firstboot.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-homed.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-hwdb-update.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-pstore.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-repart.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/systemd-sysusers.service\n' >> "/mnt/root/start.sh"
    printf 'ln -s /dev/null /etc/systemd/system/first-boot-complete.target\n' >> "/mnt/root/start.sh"
    if [ -e "/mnt/usr/bin/fsck.btrfs" ]; then
        printf 'cp /usr/bin/fsck.btrfs /usr/local/bin/\n'  >> "/mnt/root/start.sh"
        printf 'ln -s /usr/lib/systemd/system/btrfs-scrub@.timer "/etc/systemd/system/timers.target.wants/btrfs-scrub@-.timer"\n' >> "/mnt/root/start.sh"
    fi
    printf 'timedatectl set-ntp true\n' >> "/mnt/root/start.sh"
    printf 'reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist\n' >> "/mnt/root/start.sh"
    printf 'update-ca-trust\n' >> "/mnt/root/start.sh"
    printf "usermod -c \"Server $(hostname)\" root\n"
    printf "git config --global user.name \"Server $(hostname)\"\n" >> "/mnt/root/start.sh"
    printf "git config --global user.email \"$(hostname)@archlinux.com\"\n" >> "/mnt/root/start.sh"
    printf 'exit\n' >> "/mnt/root/start.sh"
    chmod 555 "/mnt/root/start.sh"
    genfstab -U -p /mnt > "/mnt/etc/fstab"
    printf 'tmpfs\t/dev/shm\ttmpfs\trw,noexec,nosuid,nodev\t0 0' >> "/mnt/etc/fstab"
    if [ $? -ne 0 ]; then
        bail "genfstab returned a non-zero error code!"
    fi
    if [[ "$SETUP_FS" != "xfs" ]]; then
        sed -i -e 's/relatime/noatime/g' "/mnt/etc/fstab"
        rm -f "/mnt/etc/fstabe"
    fi
    log "Build complete, starting chroot.."
    arch-chroot /mnt "/root/start.sh"
    if [ $? -ne 0 ]; then
        bail "arch-chroot returned a non-zero error code!"
    fi
    log "Chroot finished!"
    if [ $SETUP_EFI -eq 1 ]; then
        log "Configuring EFI boot.."
        bdisk=""
        bopts=""
        for disk in $(ls -al /dev/disk/by-uuid/ | awk '{print $9}' | grep "-"); do
            dmount=$(cat /mnt/etc/fstab | grep "UUID=${disk}" | grep "/" | awk '{print $2}')
            if [[ "${dmount}" == "/" && ${#dmount} -eq 1 ]]; then
                bdisk="${disk}"
                bopts=$(cat /mnt/etc/fstab | grep "UUID=${disk}" | grep "/" | awk '{print $4}' | sed 's/,/ /g')
            fi
        done
        if [ -z "${bdisk}" ]; then
            bail "Could not find the correct bootdisk!"
        else
            log "Bootdisk is \"${bdisk}\".."
            printf 'default\tarchlinux\ntimeout\t1\neditor\t0\n' > "/mnt/boot/loader/loader.conf"
            printf "title\tArch Linux\nlinux\t/vmlinuz-linux-hardened\ninitrd\t/initramfs-linux-hardened.img\noptions\troot=UUID=${bdisk} ${bopts}\n" > "/mnt/boot/loader/entries/archlinux.conf"
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
setup_chroot
sync

if ! [ -z "$SETUP_SCRIPT" ]; then
    source "$SETUP_SCRIPT"
fi

sync
log "Done!"

if [ $SETUP_REBOOT -eq 1 ]; then
    log "Hit CTRL+C to stop reboot and unmount of disks!"
    log "Rebooting in 5 seconds.."
    sleep 3
    log "Rebooting in 2 seconds.."
    sleep 2
    log "Unmounting and rebooting!"
    umount /mnt/boot /mnt/
    sync
    reboot
fi
