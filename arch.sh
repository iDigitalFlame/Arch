#!/usr/bin/bash
# ArchLinux Install Helper Script
#
# Copyright (C) 2020 - 2024 iDigitalFlame
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

if ! [ "$UID" = "0" ]; then
    echo "You MUST be root to do this!" 1>&2
    exit 1
fi

SETUP_AUTO=0
SETUP_REBOOT=1
SETUP_CHECK_NET=1

SETUP_NET=()
SETUP_ROOT="/mnt"
SETUP_DRIVE="/dev/sda"
SETUP_SCRIPT="$1"
SETUP_SSH_KEY=""
SETUP_HOSTNAME="archlinux"
SETUP_CONFIGURATION="/opt/sysconfig"
SETUP_DIRECTORY="${SETUP_ROOT}${SETUP_CONFIGURATION}"

declare -A SETUP_FS=( ["root"]="btrfs" ["cache"]="btrfs" )

_FS_EFI=1
# FS_TYPE is the partition and layout type.
# 0 - Standard RW Root
# 1 - Standard RO Root + Cache
# 2 - LVM RW Root
# 3 - LVM RO Root + Cache
_FS_TYPE=0
_FS_DISKS=( "sda" "vda" "xda" )

declare -A _FS_UUIDS=( ["boot"]="$(printf '%X%X%X%X-%X%X%X%X' "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))" "$((RANDOM%16))")" )

_RESULT=""

ask() {
    if [ $SETUP_AUTO -eq 1 ]; then
        bail 'Cannot ask when \x1b[1mSETUP_AUTO=1\x1b[0m'
    fi
    printf "[?] %s? " "$1"
    read -r check
    if [ -n "$check" ]; then
        _RESULT="$check"
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
log() {
    local _m="$1"; shift
    printf "\x1b[1m[+]\x1b[0m \x1b[32m${_m}\x1b[0m\n" $*
}
yes() {
    if [ $SETUP_AUTO -eq 1 ]; then
        return 0
    fi
    local _e=0
    printf "[?] %s [" "$1"
    if [[ $# -eq 2 && "${2}" = "1" ]]; then
        _e=1
        printf "Y/n]? "
    else
        printf "y/N]? "
    fi
    read -r check
    if [[ $_e -eq 1 && -z "$check" ]]; then
        return 0
    fi
    if [[ "$_e" = "Y" || "$check" = "y" ]]; then
        return 0
    fi
    return 1
}
bail() {
    local _m="$1"; shift
    printf "\x1b[1m[!]\x1b[0m \x1b[31m${_m}!\x1b[0m\n" $* 1>&2
    printf '\x1b[1m[!]\x1b[0m \x1b[31mCannot continue, quitting!\x1b[0m\n' 1>&2
    cleanup 1
    exit 1
}
cleanup() {
    sync
    umount "${SETUP_ROOT}/boot" "${SETUP_ROOT}/var" "${SETUP_ROOT}" 2> /dev/null
    sync
    if [ $# -eq 0 ]; then
        printf '\n\x1b[1m[!]\x1b[0m \x1b[31mInterrupted!\x1b[0m\n' 1>&2
        exit
    fi
}

fs_ask() {
    # fs_ask <format> <name>
    if [ $# -ne 2 ]; then
        return 1
    fi
    if yes "Use ${1} as /${2} filesystem" 1; then
        SETUP_FS["$2"]="$1"
        return 0
    fi
    local _sel=0
    while [ $_sel -eq 0 ]; do
        if ask "Select /${2} filesystem type: [btrfs/ext4/xfs]"; then
            case $_RESULT in
                "ext4")
                SETUP_FS["$2"]="ext4"
                _sel=1
                ;;
                "xfs")
                SETUP_FS["$2"]="xfs"
                _sel=1
                ;;
                "btrfs")
                SETUP_FS["$2"]="btrfs"
                _sel=1
                ;;
                *)
                ;;
            esac
        fi
    done
    return 0
}
fs_format() {
    # fs_format <name> <format> <dev> [mount_path]
    if [ $# -lt 3 ]; then
        return 1
    fi
    case "$2" in
        "xfs")
        mkfs.xfs -f -L "$1" "$3" 1> /dev/null
        ;;
        "ext4")
        mkfs.ext4 -F -L "$1" "$3" 1> /dev/null
        ;;
        *)
        mkfs.btrfs -f -L "$1" "$3" 1> /dev/null
        ;;
    esac
    if [ $? -ne 0 ]; then
        bail '\x1b[0m\x1b[1mmkfs.%s\x1b[0m\x1b[31m returned a non-zero error code' "$2"
    fi
    sleep 1
    local _uuid="$(ls -l /dev/disk/by-uuid/ | grep "$(basename "$3")" | awk '{print $9}')"
    if echo "$3" | grep -q '/mapper/'; then
        local _dm="$(basename $(ls -l /dev/mapper/ | grep "$(basename "$3")" | awk '{print $11}'))"
        if [ -n "$_dm" ]; then
            _uuid="$(ls -l /dev/disk/by-uuid/ | grep "$_dm" | awk '{print $9}')"
        fi
    fi
    if [ -z "$_uuid" ]; then
        bail 'Cannot find the UUID for \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[31m' "$3"
    fi
    _FS_UUIDS["$1"]="$_uuid"
    if [ -z "$4" ]; then
        return 0
    fi
    mkdir -p "$4" 2> /dev/null
    if [ "$2" = "btrfs" ]; then
        if ! mount -t btrfs -o noatime,compress=zstd:3,space_cache=v2 "$3" "$4"; then
            bail 'mount on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[31m returned a non-zero error code' "$4"
        fi
        if ! btrfs subvolume create "${4}/base" 1> /dev/null; then
            bail "\x1b[0m\x1b[1mbtrfs subvolume create\x1b[0m\x1b[31m returned a non-zero error code"
        fi
        if ! umount "$4"; then
            bail "\x1b[0m\x1b[1mumount\x1b[0m\x1b[32m returned a non-zero error code"
        fi
        if ! mount -t btrfs -o noatime,compress=zstd:3,space_cache=v2,subvol=/base "$3" "$4"; then
            bail 'mount on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[31m returned a non-zero error code' "$4"
        fi
        log 'Mounted \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m!' "$3" "$4"
    else
        if ! mount -o rw,noatime "$3" "$4"; then
            bail 'mount on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[31m returned a non-zero error code' "$4"
        fi
        log 'Mounted \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m!' "$3" "$4"
    fi
    return 0
}
fs_is_any() {
    if [ $# -ne 1 ]; then
        return 1
    fi
    if [ "${SETUP_FS["root"]}" = "$1" ]; then
        return 0
    fi
    if [ $_FS_TYPE -eq 1 ] || [ $_FS_TYPE -eq 3 ]; then
        return 1
    fi
    if [ "${SETUP_FS["cache"]}" = "$1" ]; then
        return 0
    fi
    return 1
}

setup_nic() {
    if [ $# -ne 1 ]; then
        return 1
    fi
    local _name="$1"
    if yes "(${_name}) Automatic Setup" 1; then
        SETUP_NET+=("${_name},,,,,")
        return 0
    fi
    local _iname="$_name"
    if ask "(${_iname}) Rename this interface"; then
        _iname="$_RESULT"
    fi
    if yes "(${_iname}) Use DHCP for this interface" 1; then
        SETUP_NET+=("${_name},${_iname},,,,")
        return 0
    fi
    local _addr=$(ip addr show dev "$_name" | grep inet | grep brd | awk '{print $2}')
    local _gateway=$(ip route | grep 'default' | awk '{print $3}' | head -1)
    if ask "(${_iname}) IPv4 Address [${_addr}]"; then
        _addr="$_RESULT"
    fi
    if ask "(${_iname}) IPv4 Gateway [${_gateway}]"; then
        _gateway="$_RESULT"
    fi
    local _servers=$(grep nameserver "/etc/resolv.conf" | grep -v '#' | awk '{print $2}' | head -2)
    local _dns1=$(echo "$_servers" | head -1)
    local _dns2=$(echo "$_servers" | tail -1)
    if ask "(${_iname}) Primary DNS Server [${_dns1}]"; then
        _dns1="$_RESULT"
    fi
    if ask "(${_iname}) Secondary DNS Server [${_dns2}] (Optional)"; then
        _dns2="$_RESULT"
    fi
    SETUP_NET+=("${_name},${_iname},${_addr},${_gateway},${_dns1},${_dns2}")
    return 0
}
setup_init() {
    if [ $SETUP_CHECK_NET -eq 1 ]; then
        if ! ping -c 1 google.com 1> /dev/null 2> /dev/null; then
            bail "No internet connection! How did you get this script?"
        fi
    fi
    log "Checking current system keyring.."
    pacman-key --init 1> /dev/null
    pacman-key --populate archlinux 1> /dev/null
    pacman -Syy 1> /dev/null
    pacman -S archlinux-keyring --noconfirm 1> /dev/null
    if ! efibootmgr 1> /dev/null 2> /dev/null; then
        _FS_EFI=0
    fi
    if [ $SETUP_AUTO -eq 1 ]; then
        return 0
    fi
    if ask "System Hostname: [${SETUP_HOSTNAME}]"; then
        SETUP_HOSTNAME="$_RESULT"
    fi
    for i in $(ip link show | grep ': <' | awk -F':' '/,/{gsub(/ /, "", $2); print $2}' | grep -v 'lo'); do
        setup_nic "$i"
    done
    if yes "Use LVM"; then
        _FS_TYPE=2
    fi
    if yes "Use read-only root" 1; then
        if [ $_FS_TYPE -eq 2 ]; then
            _FS_TYPE=3
        else
            _FS_TYPE=1
        fi
    fi
    fs_ask "btrfs" "root"
    if [ $_FS_TYPE -eq 1 ] || [ $_FS_TYPE -eq 3 ]; then
        fs_ask "btrfs" "var"
    fi
    if yes "Autodetect Disk" 1; then
        for i in ${_FS_DISKS[@]}; do
            SETUP_DRIVE="/dev/${i}"
            if [ -b "$SETUP_DRIVE" ]; then
                break
            fi
        done
    else
        SETUP_DRIVE=""
    fi
    if [ -z "$SETUP_DRIVE" ] || ! [ -b "$SETUP_DRIVE" ]; then
        while [ -z "$SETUP_DRIVE"  ]; do
            lsblk 2> /dev/null
            if ask "Select a Disk to use"; then
                if [ -b "$_RESULT" ]; then
                    SETUP_DRIVE="$_RESULT"
                fi
            fi
        done
    fi
    if [ -z "$SETUP_DRIVE" ]; then
        bail "No drive found"
    fi
}
setup_disk() {
    log 'Creating partitions on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "$SETUP_DRIVE"
    umount "${SETUP_DRIVE}"* 2> /dev/null
    local _lvm=$(lvdisplay | grep "LV Path" | awk '{print $3}')
    if [ -n "$_lvm" ]; then
        if ! yes "Remove current LVM partitions" 1; then
            bail "Clear disks manually, then restart"
        fi
        for i in $_lvm; do
            umount "$i" 2> /dev/null
            lvremove --force "$i" 1> /dev/null 2> /dev/null
        done
        for i in $(vgdisplay | grep "VG Name" | awk '{print $3}'); do
            vgremove --force "$i" 1> /dev/null 2> /dev/null
        done
        for i in $(pvdisplay | grep "PV Name" | awk '{print $3}'); do
            pvremove --force "$i" 1> /dev/null 2> /dev/null
        done
        sync
        partprobe 1> /dev/null 2> /dev/null
    fi
    log 'Wiping \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "$SETUP_DRIVE"
    printf "g\nw\n" | fdisk --wipe always "$SETUP_DRIVE"
    partprobe 1> /dev/null 2> /dev/null
    local _var=6 # Default to 6GB for /var
    local _size=$(( $(lsblk -o SIZE -nbd "$SETUP_DRIVE") / 1073741824 ))
    if [ $_size -gt 10 ] && [ $_size -le 20 ]; then
        _var=12 # Use 12G when the disk is > 10GB but < 20GB
    elif [ $_size -gt 24 ]; then
        _var=16 # Use 16GB for anything larger than 24GB
    fi
    local _devs=("${SETUP_DRIVE}2" "${SETUP_DRIVE}3" "${SETUP_DRIVE}4")
    local _fstr="g\nn\n\n\n+1M\nt\n4\nn\n\n\n+200M\nt\n2\nc\n"
    if [ $_FS_EFI -eq 1 ]; then
        _devs=("${SETUP_DRIVE}1" "${SETUP_DRIVE}2" "${SETUP_DRIVE}3")
        _fstr="g\nn\n\n\n+512M\nt\n1\n"
    fi
    if [ $_FS_TYPE -eq 1 ]; then
        _fstr="${_fstr}n\n\n\n+${_var}G\nn\n\n\n\nw\n"
    else
        _fstr="${_fstr}n\n\n\n\n\nw"
    fi
    if ! printf "$_fstr" | fdisk "$SETUP_DRIVE"; then
        bail "\x1b[0m\x1b[1mfdisk\x1b[0m\x1b[32m returned a non-zero error code"
    fi
    partprobe 1> /dev/null 2> /dev/null
    log 'Formatting boot partition \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "${_devs[0]}"
    if ! mkfs.fat -n BOOT -F32 -i "$(echo "${_FS_UUIDS["boot"]}" | sed -e 's/-//g')" "${_devs[0]}" 1> /dev/null; then
        bail "\x1b[0m\x1b[1mmkfs.vfat\x1b[0m\x1b[32m returned a non-zero error code"
    fi
    if [ $_FS_TYPE -ge 2 ]; then
        log 'Creating LVM partitions on \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "${_devs[1]}"
        if ! pvcreate --force --yes "${_devs[1]}" 1> /dev/null; then
            bail "\x1b[0m\x1b[1mpvcreate\x1b[0m\x1b[32m returned a non-zero error code"
        fi
        if ! vgcreate --force --yes storage "${_devs[1]}" 1> /dev/null; then
            bail "\x1b[0m\x1b[1mvgcreate\x1b[0m\x1b[32m returned a non-zero error code"
        fi
        if [ $_FS_TYPE -eq 3 ]; then
            if ! lvcreate --yes -n cache storage -L "${_var}G" 1> /dev/null; then
                bail "\x1b[0m\x1b[1lvgcreate\x1b[0m\x1b[32m returned a non-zero error code"
            fi
            _devs[2]="/dev/mapper/storage-cache"
        fi
        if ! lvcreate --yes -n root storage -l 100%FREE 1> /dev/null; then
                bail "\x1b[0m\x1b[1lvgcreate\x1b[0m\x1b[32m returned a non-zero error code"
        fi
        _devs[1]="/dev/mapper/storage-root"
    fi
    if [ $_FS_TYPE -eq 1 ] || [ $_FS_TYPE -eq 3 ]; then
        log 'Formatting root partition \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "${_devs[2]}"
        fs_format "root" "${SETUP_FS["root"]}" "${_devs[2]}" "$SETUP_ROOT"
        log 'Formatting cache partition \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "${_devs[1]}"
        fs_format "cache" "${SETUP_FS["var"]}" "${_devs[1]}" "${SETUP_ROOT}/var"
    else
        log 'Formatting root partition \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "${_devs[1]}"
        fs_format "root" "${SETUP_FS["root"]}" "${_devs[1]}" "$SETUP_ROOT"
    fi
    mkdir -p "${SETUP_ROOT}/boot"
    if ! mount "${_devs[0]}" "${SETUP_ROOT}/boot"; then
        bail "\x1b[0m\x1b[1mmount\x1b[0m\x1b[32m returned a non-zero error code"
    fi
    log 'Mounted \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m to \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m.' "${_devs[0]}" "${SETUP_ROOT}/boot"
}
setup_config() {
    log "Starting configuration.."
    mkdir -p "${SETUP_DIRECTORY}/etc/udev/rules.d"
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/network"
    mkdir -p "${SETUP_ROOT}/etc/systemd/system/timers.target.wants"
    mkdir -p "${SETUP_ROOT}/etc/systemd/system/sockets.target.wants"
    mkdir -p "${SETUP_ROOT}/etc/systemd/system/sysinit.target.wants"
    mkdir -p "${SETUP_ROOT}/etc/systemd/system/network-online.target.wants"

    for i in ${SETUP_NET[@]}; do
        local _name=$(echo "$i" | awk -F, '{print $1}')
        local _alias=$(echo "$i" | awk -F, '{print $2}')
        local _addr=$(echo "$i" | awk -F, '{print $3}')
        local _gateway=$(echo "$i" | awk -F, '{print $4}')
        local _dns1=$(echo "$i" | awk -F, '{print $5}')
        local _dns2=$(echo "$i" | awk -F, '{print $6}')
        log 'Configuring interface \x1b[0m\x1b[1m"%s"\x1b[0m\x1b[32m..' "$_name"
        if [ -n "$_alias" ]; then
            local _mac=$(ip link show "${_name}" | grep 'ether' | awk '{print $2}')
            printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="%s", NAME="%s"\n' "$_mac" "$_alias" >> "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            chmod 0400 "${SETUP_DIRECTORY}/etc/udev/rules.d/10-network.rules"
            _name="$_alias"
        fi
        printf "[Match]\nName=%s\n\n" "$_name" > "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        if [ -z "${_addr}" ]; then
            printf "[Network]\nDHCP=yes\n\n[DHCP]\nUseDomains=yes\n" >> "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        else
            printf "[Network]\nAddress=%s\n" "$_addr" >> "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        fi
        if [ -n "${_dns1}" ]; then
            printf "DNS=%s\n" "$_dns1" >> "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        fi
        if [ -n "${_dns2}" ]; then
            printf "DNS=%s\n" "$_dns2" >> "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        fi
        if [ -n "${_gateway}" ]; then
            printf "\n[Route]\nGateway=%s\n" "$_gateway" >> "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
        fi
        chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/network/${_name}.network"
    done

    # NOTE(dij): We setup the proper stuff to atleast boot correctly before calling the
    #            custom script helper.
    touch "${SETUP_DIRECTORY}/etc/vconsole.conf"
    local _rw_type=$([ $_FS_TYPE -eq 1 ] || [ $_FS_TYPE -eq 3 ] && echo "ro" || echo "rw")
    if [ $_FS_EFI -eq 0 ]; then
        mkdir -p "${SETUP_DIRECTORY}/etc/default"
        printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=1\nGRUB_GFXMODE=auto\nGRUB_SAVEDEFAULT=true\nGRUB_CMDLINE_LINUX=""\nGRUB_DISTRIBUTOR="Arch"\nGRUB_TIMEOUT_STYLE=hidden\n' > "${SETUP_DIRECTORY}/etc/default/grub"
        printf 'GRUB_DISABLE_SUBMENU=true\nGRUB_DISABLE_RECOVERY=true\nGRUB_GFXPAYLOAD_LINUX=keep\nGRUB_TERMINAL_INPUT=console\nGRUB_DISABLE_OS_PROBER=true\n' >> "${SETUP_DIRECTORY}/etc/default/grub"
        printf 'GRUB_PRELOAD_MODULES="part_gpt lvm part_msdos"\nGRUB_CMDLINE_LINUX_DEFAULT="%s quiet"\n' "$_rw_type" >> "${SETUP_DIRECTORY}/etc/default/grub"
    fi
    printf 'COMPRESSION="zstd"\nCOMPRESSION_OPTIONS=(-9)\nMODULES_DECOMPRESS="yes"\nBINARIES=(' > "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    local _is_btrfs=$(fs_is_any "btrfs"; echo $?)
    if [ $_is_btrfs -eq 0 ]; then
        printf "btrfs)\nFILES=(/usr/bin/btrfs)\nHOOKS=(" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    else
        printf ")\nFILES=()\nHOOKS=(" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    printf 'systemd autodetect microcode modconf block sd-vconsole' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    if [ $_FS_TYPE -ge 2 ]; then
        printf " lvm2" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    if [ $_is_btrfs -eq 0 ]; then
        printf " btrfs" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi
    printf ' filesystems' >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    if [ "${SETUP_FS["root"]}" = "btrfs" ]; then
        printf ")\n" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    else
        printf " fsck)\n" >> "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    fi

    log "Adding configuration.."
    if [ -n "$SETUP_SSH_KEY" ]; then
        log "Adding root SSH public key.."
        mkdir -p "${SETUP_ROOT}/root/.ssh" 2> /dev/null
        printf "%s\n" "$SETUP_SSH_KEY" > "${SETUP_ROOT}/root/.ssh/authorized_keys"
        chmod 0500 "${SETUP_ROOT}/root/.ssh"
        chmod 0400 "${SETUP_ROOT}/root/.ssh/authorized_keys"
    fi

    mkdir -p "${SETUP_ROOT}/var/db/pacman"
    mkdir -p "${SETUP_ROOT}/var/cache/pacman"
    chmod 0555 "${SETUP_ROOT}/var/db/pacman"

    mv "${SETUP_ROOT}/etc/ld.so.cache" "${SETUP_ROOT}/var/cache/ld.so.cache"
    mv "${SETUP_ROOT}/etc/pacman.d/gnupg" "${SETUP_ROOT}/var/db/pacman/gnupg"
    mv "${SETUP_ROOT}/etc/pacman.d/mirrorlist" "${SETUP_ROOT}/var/cache/pacman/mirrorlist"

    ln -sT "/var/cache/ld.so.cache" "${SETUP_ROOT}/etc/ld.so.cache"
    ln -sT "/var/db/pacman/gnupg" "${SETUP_ROOT}/etc/pacman.d/gnupg"
    ln -sT "/var/cache/pacman/mirrorlist" "${SETUP_ROOT}/etc/pacman.d/mirrorlist"

    printf 'proc                                        /proc       proc    rw,nosuid,noexec,nodev,noatime,hidepid=invisible,gid=proc                                                                       0 0\n' > "${SETUP_ROOT}/etc/fstab"
    printf 'tmpfs                                       /tmp        tmpfs   rw,nosuid,nodev,noatime                                                                                                         0 0\n' >> "${SETUP_ROOT}/etc/fstab"
    printf 'tmpfs                                       /dev/shm    tmpfs   rw,nosuid,noexec,nodev,noatime                                                                                                  0 0\n' >> "${SETUP_ROOT}/etc/fstab"
    printf "UUID=${_FS_UUIDS["boot"]}                              /boot       vfat    ro,nosuid,noexec,nodev,noatime,fmask=0137,dmask=0027,codepage=437,iocharset=iso8859-1,shortname=mixed,utf8,errors=remount-ro    0 2\n" >> "${SETUP_ROOT}/etc/fstab"
    printf "UUID=${_FS_UUIDS["root"]}   /           " >> "${SETUP_ROOT}/etc/fstab"
    case "${SETUP_FS["root"]}" in
        "xfs")
        printf "xfs     ${_rw_type},nodev,noatime,noquota,inode64                                                                                                0 0\n" >> "${SETUP_ROOT}/etc/fstab"
        ;;
        "ext4")
        printf "ext4    ${_rw_type},nodev,noatime,discard                                                                                                        0 0\n" >> "${SETUP_ROOT}/etc/fstab"
        ;;
        *)
        printf "btrfs   ${_rw_type},nodev,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/base,discard=async                                                  0 0\n" >> "${SETUP_ROOT}/etc/fstab"
        ;;
    esac
    if [ "$_rw_type" = "ro" ]; then
        printf "UUID=${_FS_UUIDS["cache"]}   /var        " >> "${SETUP_ROOT}/etc/fstab"
        case "${SETUP_FS["var"]}" in
            "xfs")
            printf "xfs     rw,nosuid,noexec,nodev,noatime,noquota,inode64                                                                                  0 0\n" >> "${SETUP_ROOT}/etc/fstab"
            ;;
            "ext4")
            printf "ext4    rw,nosuid,noexec,nodev,noatime,discard                                                                                          0 0\n" >> "${SETUP_ROOT}/etc/fstab"
            ;;
            *)
            printf "btrfs   rw,nosuid,noexec,nodev,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/base,discard=async                                    0 0\n" >> "${SETUP_ROOT}/etc/fstab"
            ;;
        esac
    fi
    chmod 0444 "${SETUP_ROOT}/etc/fstab"

    printf "%s\n" "$SETUP_HOSTNAME" > "${SETUP_DIRECTORY}/etc/motd"
    printf "%s" "$SETUP_HOSTNAME" > "${SETUP_DIRECTORY}/etc/hostname"
    printf "127.0.0.1    localhost\n172.0.0.1    %s\n" "$SETUP_HOSTNAME" >> "${SETUP_DIRECTORY}/etc/hosts"

    printf 'SYSCONFIG="%s"\n' "$SETUP_CONFIGURATION" > "${SETUP_ROOT}/etc/sysconfig.conf"
    if [ "$_rw_type" = "ro" ]; then
        printf "SYSCONFIG_SECURE=1\n" >> "${SETUP_ROOT}/etc/sysconfig.conf"
    fi

    rm "${SETUP_ROOT}/etc/localtime" 2> /dev/null
    ln -sT "/usr/share/zoneinfo/America/New_York" "${SETUP_ROOT}/etc/localtime"

    if setup_custom; then
        log "Configuration setup complete!"
        return 0
    fi

    log "Using configuration defaults.."

    ln -sT "/etc/systemd/system/reflector.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/reflector.timer"
    ln -sT "/etc/systemd/system/reflector.service" "${SETUP_ROOT}/etc/systemd/system/multi-user.target.wants/reflector.service"

    ln -sT "/usr/lib/systemd/system/fstrim.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/fstrim.timer"
    ln -sT "/usr/lib/systemd/system/sshd.service" "${SETUP_ROOT}/etc/systemd/system/multi-user.target.wants/sshd.service"
    ln -sT "/usr/lib/systemd/system/logrotate.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/logrotate.timer"
    ln -sT "/usr/lib/systemd/system/systemd-networkd.socket" "${SETUP_ROOT}/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
    ln -sT "/usr/lib/systemd/system/systemd-timesyncd.service" "${SETUP_ROOT}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
    ln -sT "/usr/lib/systemd/system/systemd-networkd.service" "${SETUP_ROOT}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
    ln -sT "/usr/lib/systemd/system/systemd-resolved.service" "${SETUP_ROOT}/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
    ln -sT "/usr/lib/systemd/system/systemd-networkd-wait-online.service" "${SETUP_ROOT}/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"

    if [ "${SETUP_FS["root"]}" = "btrfs" ]; then
        ln -sT "/usr/lib/systemd/system/btrfs-scrub@.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/btrfs-scrub@-.timer"
        if [ "$_rw_type" = "ro" ]; then
            mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system/btrfs-scrub@-.service.d" 2> /dev/null
            printf '[Service]\nExecStartPre = -/usr/bin/mount -o rw,remount /\nExecStopPost = -/usr/bin/bash -c "mount -o ro,remount / 2> /dev/null || mount -Ro ro,remount /"\n' > "${SETUP_DIRECTORY}/etc/systemd/system/btrfs-scrub@-.service.d/override.conf"
            chmod 0555 "${SETUP_DIRECTORY}/etc/systemd/system/btrfs-scrub@-.service.d"
            chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/system/btrfs-scrub@-.service.d/override.conf"
        fi
    fi
    if [ "$_rw_type" = "ro" ] && [ "${SETUP_FS["var"]}" = "btrfs" ]; then
        ln -sT "/usr/lib/systemd/system/btrfs-scrub@.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/btrfs-scrub@var.timer"
    fi
    if fs_is_any "xfs"; then
        ln -sT "/usr/lib/systemd/system/xfs_scrub_all.timer" "${SETUP_ROOT}/etc/systemd/system/timers.target.wants/xfs_scrub_all.timer"
    fi

    rm -f "${SETUP_ROOT}/etc/systemd/system/home.mount"
    rm -f "${SETUP_ROOT}/etc/systemd/system/syslog.target"
    rm -f "${SETUP_ROOT}/etc/systemd/system/rescue.target"
    rm -f "${SETUP_ROOT}/etc/systemd/system/rescue.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/syslog.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/emergency.target"
    rm -f "${SETUP_ROOT}/etc/systemd/system/emergency.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/debug-shell.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-bsod.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-homed.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/var-lib-machines.mount"
    rm -f "${SETUP_ROOT}/etc/systemd/system/plymouth-start.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-pstore.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-repart.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/display-manager.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-sysusers.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-firstboot.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/first-boot-complete.target"
    rm -f "${SETUP_ROOT}/etc/systemd/system/plymouth-quit-wait.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-boot-update.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-hwdb-update.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-boot-system-token.service"
    rm -f "${SETUP_ROOT}/etc/systemd/system/systemd-network-generator.service"

    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/home.mount"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/syslog.target"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/rescue.target"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/rescue.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/syslog.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/emergency.target"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/emergency.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/debug-shell.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-bsod.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-homed.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/var-lib-machines.mount"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/plymouth-start.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-pstore.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-repart.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/display-manager.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-sysusers.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-firstboot.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/first-boot-complete.target"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/plymouth-quit-wait.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-quotacheck.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-boot-update.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-hwdb-update.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-boot-system-token.service"
    ln -sT "/dev/null" "${SETUP_ROOT}/etc/systemd/system/systemd-network-generator.service"

    setup_defaults

    if [ "$_rw_type" = "ro" ]; then
        /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-root.hook"
        /usr/bin/printf 'on   = Install\nOperation   = Upgrade\n\n[Action]\nWhen        = PreTransaction\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-root.hook"
        /usr/bin/printf 'Exec        = /usr/bin/mount -o remount,rw /\nDescription = Mounting / as read/w' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-root.hook"
        /usr/bin/printf 'rite..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-root.hook"
        /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-root.hook"
        /usr/bin/printf 'on   = Install\nOperation   = Upgrade\n\n[Action]\nWhen        = PostTransaction' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-root.hook"
        /usr/bin/printf '\nExec        = /usr/bin/bash -c "mount -ro remount,ro / 2> /dev/null || mount -' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-root.hook"
        /usr/bin/printf 'Rro remount,ro /"\nDescription = Mounting / as read only..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-root.hook"
    fi

    log "Configuration setup complete!"

    chmod 0444 "${SETUP_ROOT}/etc/sysconfig.conf"
    chmod 0555 "${SETUP_ROOT}/etc/systemd/system/timers.target.wants"
    chmod 0555 "${SETUP_ROOT}/etc/systemd/system/sockets.target.wants"
    chmod 0555 "${SETUP_ROOT}/etc/systemd/system/sysinit.target.wants"
    chmod 0555 "${SETUP_ROOT}/etc/systemd/system/network-online.target.wants"
    chmod 0400 "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    chmod 0400 "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"
    chmod 0400 "${SETUP_DIRECTORY}/etc/security/limits.d/limits.conf"
    chmod 0400 "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    chmod 0400 "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    chmod 0400 "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"
    chmod 0400 "${SETUP_DIRECTORY}/etc/vconsole.conf"
    chmod 0440 "${SETUP_DIRECTORY}/etc/mkinitcpio.conf"
    chmod 0444 "${SETUP_DIRECTORY}/etc/hostname"
    chmod 0444 "${SETUP_DIRECTORY}/etc/hosts"
    chmod 0444 "${SETUP_DIRECTORY}/etc/locale.gen"
    chmod 0444 "${SETUP_DIRECTORY}/etc/motd"
    chmod 0444 "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    chmod 0444 "${SETUP_DIRECTORY}/etc/sysless"
    chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    chmod 0444 "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    chmod 0550 "${SETUP_DIRECTORY}/etc/modprobe.d"
    chmod 0550 "${SETUP_DIRECTORY}/etc/pacman.d/hooks"
    chmod 0550 "${SETUP_DIRECTORY}/etc/security/limits.d"
    chmod 0550 "${SETUP_DIRECTORY}/etc/syscheck.d"
    chmod 0550 "${SETUP_DIRECTORY}/etc/syscheck.d"
    chmod 0550 "${SETUP_DIRECTORY}/etc/sysctl.d"
    chmod 0550 "${SETUP_DIRECTORY}/etc/udev/rules.d"
    chmod 0555 "${SETUP_DIRECTORY}/bin"
    chmod 0555 "${SETUP_DIRECTORY}/etc/pacman.d/hooks"
    chmod 0555 "${SETUP_DIRECTORY}/etc/profile.d"
    chmod 0555 "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"
    chmod 0555 "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    chmod 0555 "${SETUP_DIRECTORY}/etc/ssh"
    chmod 0555 "${SETUP_DIRECTORY}/etc/systemd/network"
    chmod 0555 "${SETUP_DIRECTORY}/etc/systemd/system"
    chmod 0555 "${SETUP_DIRECTORY}"/bin/*
    chmod 0400 "${SETUP_DIRECTORY}"/etc/pacman.d/hooks/*
    chmod 0444 "${SETUP_DIRECTORY}"/etc/systemd/system/*

    rm -f "${SETUP_ROOT}"/etc/ssh/*key* 2> /dev/null
    awk '$5 > 2000' "${SETUP_ROOT}/etc/ssh/moduli" > "${SETUP_ROOT}/etc/ssh/moduli"
    ssh-keygen -t rsa -b 4096 -f "${SETUP_ROOT}/etc/ssh/ssh_host_rsa_key" -N "" < /dev/null > /dev/null
    ssh-keygen -t ed25519 -f "${SETUP_ROOT}/etc/ssh/ssh_host_ed25519_key" -N "" < /dev/null > /dev/null
    chmod 0400 "${SETUP_ROOT}"/etc/ssh/ssh_host_*

    log "Configuration complete!"
}
setup_chroot() {
    log "Building chroot script.."
    mkdir "${SETUP_ROOT}/tmplvm"
    mount --bind "/run/lvm" "${SETUP_ROOT}/tmplvm"
    printf '#!/bin/bash\n\n' > "${SETUP_ROOT}/root/start.sh"
    printf 'ln -s /tmplvm /run/lvm\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'vgscan -v 2> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    printf "bash %s/bin/relink %s / 1> /dev/null\n" "$SETUP_CONFIGURATION" "$SETUP_CONFIGURATION" >> "${SETUP_ROOT}/root/start.sh"
    printf "bash %s/bin/syslink 1> /dev/null\n" "$SETUP_CONFIGURATION" >> "${SETUP_ROOT}/root/start.sh"
    printf 'mount -o rw,remount /\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'locale-gen 1> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'mkinitcpio -p linux-hardened\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'printf "archlinux\\narchlinux" | passwd root 1> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    if [ $_FS_EFI -eq 1 ]; then
        printf "bootctl install 1> /dev/null\n" >> "${SETUP_ROOT}/root/start.sh"
    else
        printf "grub-install %s 1> /dev/null\n" "$SETUP_DRIVE" >> "${SETUP_ROOT}/root/start.sh"
        printf "grub-mkconfig -o /boot/grub/grub.cfg 1> /dev/null\n" >> "${SETUP_ROOT}/root/start.sh"
    fi
    printf 'timedatectl set-ntp true 2> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'pacman -Rsc $(pacman -Qtdq) --noconfirm 2> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'mount -o rw,remount /\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'env XDG_CACHE_HOME=/var/cache/pacman reflector --protocol https --latest 30 --number 20 --sort rate --save "/var/cache/pacman/mirrorlist"\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'update-ca-trust\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'usermod -c "Server %s" root\n' "$SETUP_HOSTNAME" >> "${SETUP_ROOT}/root/start.sh"
    printf 'git config --global user.name "Server %s" 1> /dev/null\n' "$SETUP_HOSTNAME" >> "${SETUP_ROOT}/root/start.sh"
    printf 'git config --global user.email "%s@localhost" 1> /dev/null\n' "$SETUP_HOSTNAME" >> "${SETUP_ROOT}/root/start.sh"
    printf 'git lfs install 1> /dev/null\n' >> "${SETUP_ROOT}/root/start.sh"
    printf 'exit\n' >> "${SETUP_ROOT}/root/start.sh"
    chmod 0555 "${SETUP_ROOT}/root/start.sh"
    mount -o rw,remount "${SETUP_ROOT}"
    mount -o rw,remount "${SETUP_ROOT}/boot"
    log "Build complete, starting chroot.."
    if ! arch-chroot "${SETUP_ROOT}" "/root/start.sh"; then
        bail "\x1b[0m\x1b[1march-chroot\x1b[0m\x1b[31m returned a non-zero error code"
    fi
    log "Chroot complete!"
    mount -o rw,remount "${SETUP_ROOT}"
    mount -o rw,remount "${SETUP_ROOT}/boot"
    find "${SETUP_ROOT}" -type f -name "*.pacnew" -delete 2> /dev/null
    find "${SETUP_ROOT}" -type f -name "*.pacsave" -delete 2> /dev/null

    log "Cleaning up.."
    rm -f "${SETUP_ROOT}/root/start.sh"
    rm -f "${SETUP_ROOT}/etc/resolv.conf"
    ln -sT "/run/systemd/resolve/resolv.conf" "${SETUP_ROOT}/etc/resolv.conf"
    umount "${SETUP_ROOT}/tmplvm"
    rmdir "${SETUP_ROOT}/tmplvm"

    if [ $_FS_EFI -eq 1 ]; then
        printf 'default\tarchlinux\ntimeout\t1\neditor\t0\n' > "${SETUP_ROOT}/boot/loader/loader.conf"
        printf "title\tArch Linux\nlinux\t/vmlinuz-linux-hardened\ninitrd\t/initramfs-linux-hardened.img\noptions\troot=UUID=%s " "${_FS_UUIDS["root"]}" > "${SETUP_ROOT}/boot/loader/entries/archlinux.conf"
        local _rw_type=$([ $_FS_TYPE -eq 1 ] || [ $_FS_TYPE -eq 3 ] && echo "ro" || echo "rw")
        case "${SETUP_FS["root"]}" in
            "xfs")
            printf "${_rw_type},nodev,noatime,noquota,inode64\n" >> "${SETUP_ROOT}/boot/loader/entries/archlinux.conf"
            ;;
            "ext4")
            printf "${_rw_type},nodev,noatime,discard\n" >> "${SETUP_ROOT}/boot/loader/entries/archlinux.conf"
            ;;
            *)
            printf "${_rw_type},nodev,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/base,discard=async\n" >> "${SETUP_ROOT}/boot/loader/entries/archlinux.conf"
            ;;
        esac
    fi
}
setup_custom() {
    # Add custom script stuff here to deploy (not in chroot).
    # Have this function return 0 if we shoudln't add the defaults.
    return 1
}
setup_defaults() {
    # Automatically generated build files script.
    # Args: build-config.py ./Config

    mkdir -p "${SETUP_DIRECTORY}/bin" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/modprobe.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/pacman.d/hooks" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/profile.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/security/limits.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/ssh" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/syscheck.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/sysctl.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system/ldconfig.service.d" 2> /dev/null
    mkdir -p "${SETUP_DIRECTORY}/etc/systemd/system" 2> /dev/null

    # Create file "/bin/linkcheck"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf '#!/usr/bin/bash\n\nset -u\n\nif [ $# -ne 2 ]; then\n    echo "linkcheck <link> <' >> "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf 'target>"\n    exit 1\nfi\n\n_target="$(readlink "$1" 2> /dev/null)"\nif [ $? -eq' >> "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf ' 0 ] && [ "$_target" = "$2" ]; then\n    exit 0\nfi\n\nrm -f "$1" 2> /dev/null\n' >> "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf 'if ! ln -sT "$2" "$1"; then\n    printf '\''Creating link "%%s" to "%%s" failed!' >> "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf '\\n'\'' "$1" "$2"\n    exit 1\nfi\n\nprintf '\''Link "%%s" to "%%s" created.\\n'\''' >> "${SETUP_DIRECTORY}/bin/linkcheck"
    /usr/bin/printf ' "$1" "$2"\n' >> "${SETUP_DIRECTORY}/bin/linkcheck"

    # Create file "/bin/relink"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '#!/usr/bin/bash\n\nDRY=0\nDEBUG=0\n\nif [ $# -lt 2 ]; then\n    echo "relink [--' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'debug] [--dry] <config source> <config target>"\n    exit 1\nfi\n\nlist() {\n   ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' if [ $# -ne 2 ]; then\n        return 1\n    fi\n    local list_src=${2%%/}\n  ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '  local list_target=${1%%/}\n    find "$list_target" -type f -not -wholename "$l' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'ist_target"/.git/\\* -print | while IFS= read -r list_file; do\n        local li' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'st_name=$(printf "%%s" "$list_file" | awk "{gsub(\\"${list_target}\\", \\"\\"); ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'print \\$0}")\n        if ! echo "$list_name" | grep -qE '\''.(nlk|nolink)$|^/.g' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'it(|ignore$|config$)|^/(LICENSE|license|.vscode)$|^/[a-zA-Z0-9_.-]+.(md|vscode|M' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'D|code-workspace)$'\''; then\n            check "${list_src}${list_name}" "${lis' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 't_target}${list_name}"\n        fi\n    done\n    return 0\n}\nlink() {\n    if ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '[ $# -ne 2 ]; then\n        return 1\n    fi\n    rm -f "$1" 2> /dev/null\n    l' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'ocal link_target="$(dirname "$1")"\n    if ! [ -d "$target" ]; then\n        if ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '[ $DRY -eq 0 ]; then\n            printf '\''Making "%%s"..\\n'\'' "$link_target' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '"\n            if ! mkdir -p "$link_target" 2> /dev/null; then\n                ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'printf '\''Cannot create directory "%%s"!\\n'\'' "$link_target"\n               ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' exit 1\n            fi\n            if [ "$UID" = "0" ]; then\n                ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'chmod 0555 "$link_target"\n            else\n                chmod 0755 "$link_t' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'arget"\n            fi\n        else\n            printf '\''Would make "%%s"..\\' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'n'\'' "$link_target"\n        fi\n    fi\n    if [ $DRY -ne 0 ]; then\n        p' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'rintf '\''Would link "%%s" to "%%s"!\\n'\'' "$1" "$2"\n        return 0\n    fi\n' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '    if ! ln -s "$2" "$1"; then\n        printf '\''Could not link "%%s" to "%%s"' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '!\\n'\'' "$1" "$2"\n        exit 1\n    fi\n    printf '\''Relinked "%%s" to "%%' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 's".\\n'\'' "$1" "$2"\n    return 0\n}\ncheck() {\n    if [ $# -ne 2 ]; then\n   ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '     return 1\n    fi\n    if [ $DEBUG -eq 1 ]; then\n        printf '\''Checkin' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'g "%%s"..\\n'\'' "$1"\n    fi\n    if ! [ -L "$1" ]; then\n        printf '\''Fi' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'le "%%s" is invalid, updating!\\n'\'' "$1"\n        link "$1" "$2"\n    else\n  ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '      if ! [ "$(readlink "$1")" = "$2" ]; then\n            printf '\''File "%%s' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '" is invalid, updating!\\n'\'' "$1"\n            link "$1" "$2"\n        else\n ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '           if [ $DEBUG -eq 1 ]; then\n                printf '\''File "%%s" is v' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'alid!\\n'\'' "$1"\n            fi\n        fi\n    fi\n    return 0\n}\npanic() ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '{\n    echo "[!] $1"\n    exit 1\n}\n\nif [ $# -gt 2 ]; then\n    case "$1" in\n' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '        "--dry")\n        DRY=1\n        shift\n        ;;\n        "--debug")\n' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '        DEBUG=1\n        shift\n        ;;\n        *)\n        ;;\n    esac\n  ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '  case "$1" in\n        "--dry")\n        DRY=1\n        shift\n        ;;\n    ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '    "--debug")\n        DEBUG=1\n        shift\n        ;;\n        *)\n        ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ';;\n    esac\nfi\n\nif [ $DRY -eq 0 ]; then\n    if ! [ -d "$1" ]; then\n       ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' printf '\''Error: source directory "%%s" does not exist!'\'' "$1"\n    fi\n    ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf 'if ! [ -d "$2" ]; then\n        if ! mkdir -p "$2" 2> /dev/null; then\n         ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf '   printf '\''Error: cannot create target directory "%%s"!'\'' "$2"\n           ' >> "${SETUP_DIRECTORY}/bin/relink"
    /usr/bin/printf ' exit 1\n        fi\n    fi\nfi\n\nlist "$1" "$2"\n' >> "${SETUP_DIRECTORY}/bin/relink"

    # Create file "/bin/setup_fixup"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf '#!/usr/bin/bash\n\nif ! [ "$UID" = "0" ]; then\n    echo "Error: root is require' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'd!"\n    exit 1\nfi\n\nif [ $# -ne 1 ]; then\n    echo "setup_fixup <sysconfig d' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'ir>"\n    exit 2\nfi\nif [ ! -d "$1" ]; then\n    printf '\''Error: path "%%s" i' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 's not valid!\\n'\'' "$1"\n    exit 1\nfi\n\nfixup_packages() {\n    if [ $# -ne ' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf '1 ]; then\n        return\n    fi\n    if [ ! -f "$1" ]; then\n        return\n ' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf '   fi\n    local _packages=()\n    while read i; do\n        if ! pacman -Qi "$i' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf '" 1> /dev/null 2> /dev/null; then\n            _packages+=($i)\n        fi\n    ' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'done < "$1"\n    if [ ${#_packages[@]} -gt 0 ]; then\n        printf "Installing' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf ' %%s packages..\\n" "${#_packages[@]}"\n        printf "Package: %%s\\n" "${_pac' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'kages[@]}"\n        pacman -Sy --noconfirm ${_packages[@]}\n    fi\n}\nfixup_sys' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'temctl() {\n    if [ $# -ne 2 ]; then\n        return\n    fi\n    if [ ! -f "$2' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf '" ]; then\n        return\n    fi\n    while read i; do\n        systemctl $1 $i' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf ' 2> /dev/null\n    done < "$2"\n}\n\nfixup_packages "${1}/packages.md"\nfixup_sy' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'stemctl mask "${1}/masked.md"\nfixup_systemctl enable "${1}/units.md"\nfixup_sys' >> "${SETUP_DIRECTORY}/bin/setup_fixup"
    /usr/bin/printf 'temctl enable "${1}/indirect.md"\n' >> "${SETUP_DIRECTORY}/bin/setup_fixup"

    # Create file "/bin/syslink"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'G" ]; then\n    echo "Error: system configuration directory not found!"\n    exi' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 't 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf '\''Error: system configurat' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'ion directory "%%s" does not exist!\\n'\'' "$SYSCONFIG"\n    exit 1\nfi\n\nSYSCO' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'NFIG=${SYSCONFIG%%/}\n\nif ! [ "$UID" = "0" ]; then\n    echo "Error: root is re' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'quired!"\n    exit 1\nfi\n\nrelink "$SYSCONFIG" /\n\npacman -Qeq 1> "${SYSCONFIG' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '}/packages.md"\ncp "/etc/fstab" "${SYSCONFIG}/etc/fstab.nlk"\nsystemctl list-uni' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 't-files | grep "masked" | awk '\''{print $1}'\'' | sort 1> "${SYSCONFIG}/masked.' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'md"\nsystemctl list-unit-files | awk '\''{print $1" "$2}'\'' | grep "enabled" | ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'grep -vE ".target|enabled-runtime" | awk '\''{print $1}'\'' | sort 1> "${SYSCONF' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'IG}/units.md"\nsystemctl list-units | grep "@." | grep -vE "dead|exited" | awk '\''' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '{print $1}'\'' | grep -vE "getty|user|blockdev" | grep "@." | sort 1> "${SYSCONF' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'IG}/indirect.md"\n\nchown -R root:root "$SYSCONFIG"\nchmod -R 0555 "$SYSCONFIG"\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '\nfind "$SYSCONFIG" -type f -exec chmod 0444 {} \\;\nfind "$SYSCONFIG" -type d -' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'exec chmod 0555 {} \\;\n\nchmod -R 0555 "${SYSCONFIG}/bin"\nchmod -R 0555 "${SYS' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'CONFIG}/etc/profile.d"\nchmod -R 0500 "${SYSCONFIG}/etc/syscheck.d"\n\nchmod 055' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '5 "${SYSCONFIG}/etc/ssh"\nchmod 0555 "${SYSCONFIG}/etc/systemd"\nchmod 0500 "${S' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'YSCONFIG}/etc/sysctl.d"\nchmod 0555 "${SYSCONFIG}/etc/security" 2> /dev/null\nch' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'mod 0440 "${SYSCONFIG}/etc/ssh/sshd_config"\nchmod 0400 "${SYSCONFIG}/etc/mkinit' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'cpio.conf" 2> /dev/null\nchmod 0500 "${SYSCONFIG}/etc/security/limits.d" 2> /dev' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '/null\nchmod 0400 "${SYSCONFIG}/etc/systemd/coredump.conf" 2> /dev/null\n\nchmod' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' 0400 "${SYSCONFIG}"/etc/sysctl.d/*\nchmod 0444 "${SYSCONFIG}"/etc/systemd/netwo' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'rk/* 2> /dev/null\nchmod 0400 "${SYSCONFIG}"/etc/security/limits.d/* 2> /dev/nul' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'l\n\nchmod -R 0555 "/etc/profile.d"\nchmod -R 0500 "/etc/syscheck.d"\n\nchmod 05' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '55 "/etc/ssh"\nchmod 0555 "/etc/systemd"\nchmod 0500 "/etc/sysctl.d"\nchmod 0555' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' "/etc/security"\nchmod 0444 "/etc/resolv.conf"\nchmod 0500 "/etc/pacman.d/hooks' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '" 2> /dev/null\nchmod 0500 "/etc/security/limits.d" 2> /dev/null\n\nchmod 0400 /' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'etc/sysctl.d/*\nchmod 0444 /etc/systemd/network/* 2> /dev/null\nchmod 0400 /etc/' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'security/limits.d/* 2> /dev/null\n\nchown -R root:root "/etc/ssh"\nchown -R root' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ':root "/etc/systemd"\nchown -R root:root "/etc/sysctl.d"\nchown -R root:root "/e' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'tc/security"\nchown -R root:root "/etc/profile.d"\nchown -R root:root "/etc/sysc' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'heck.d"\nchown -R root:root "/etc/resolv.conf"\n\nfind "/etc/ssh" -type f -exec ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'chmod 0400 {} \\;\nfind "/etc/systemd" -type f -exec chmod 0444 {} \\;\nfind "/e' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'tc/security" -type f -exec chmod 0440 {} \\;\n\nif [ -e "/etc/pacman.conf" ]; th' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'en\n    chmod 0444 "${SYSCONFIG}/etc/pacman.conf"\n    chmod 0500 "${SYSCONFIG}/' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'etc/pacman.d/hooks"\n    chmod 0400 "${SYSCONFIG}"/etc/pacman.d/hooks/*\n    chm' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'od 0555 "/etc/pacman.d"\n    chmod 0400 /etc/pacman.d/hooks/*\n    chown -R root' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ':root "/etc/pacman.d"\n    find "/etc/pacman.d" -maxdepth 1 -type f -exec chmod ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '0444 {} \\;\nfi\nif [ -e "${SYSCONFIG}/etc/udev" ]; then\n    chown -R root:root' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' "/etc/udev"\n    chmod -R 0555 "${SYSCONFIG}/etc/udev"\n    find "/etc/udev/" -' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'xdev -type f -exec chmod 0444 {} \\;\nfi\nif [ -e "${SYSCONFIG}/etc/tmpfiles.d" ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ']; then\n    chown -R root:root "/etc/tmpfiles.d"\n    chmod 0550 "${SYSCONFIG}/' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'etc/tmpfiles.d"\n    chmod 0440 "${SYSCONFIG}"/etc/tmpfiles.d/*\n    chmod 0550 ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '"/etc/tmpfiles.d"\n    chmod 0440 /etc/tmpfiles.d/*\nfi\nif [ -e "${SYSCONFIG}/e' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'tc/modprobe.d" ]; then\n    chown -R root:root "/etc/modprobe.d"\n    chmod 0500' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf ' "${SYSCONFIG}/etc/modprobe.d"\n    chmod 0400 "${SYSCONFIG}"/etc/modprobe.d/*\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '    chmod 0500 "/etc/modprobe.d"\nfi\nif [ -e "${SYSCONFIG}/etc/sysupdate.d" ]; ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'then\n    chown -R root:root "/etc/sysupdate.d"\n    chmod 0550 "${SYSCONFIG}/et' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'c/sysupdate.d"\n    chmod 0550 "${SYSCONFIG}"/etc/sysupdate.d/*\n    chmod 0550 ' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '"/etc/sysupdate.d"\nfi\nif [ -e "${SYSCONFIG}/etc/nftables.conf" ]; then\n    ch' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'mod 0400 "${SYSCONFIG}/etc/nftables.conf"\nfi\n\nif [ -d "/etc/syscheck.d" ]; th' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'en\n    for entry in /etc/syscheck.d/*.sh; do\n        if [ -f "$entry" ]; then\n' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf '            printf '\''Processing script "%%s"..\\n'\'' "$entry"\n            so' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'urce "$entry"\n        fi\n    done\nfi\n\nsync\necho "Broken Links Found:"\nfin' >> "${SETUP_DIRECTORY}/bin/syslink"
    /usr/bin/printf 'd /etc -xtype l -xdev 2> /dev/null | grep -vE "/proc|/tmp|/run"\necho "Done!"\n' >> "${SETUP_DIRECTORY}/bin/syslink"

    # Create file "/bin/syspull"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'G" ]; then\n    echo "Error: system configuration directory not found!"\n    exi' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 't 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf '\''Error: system configurat' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'ion directory "%%s" does not exist!\\n'\'' "$SYSCONFIG"\n    exit 1\nfi\n\nSYSCO' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'NFIG=${SYSCONFIG%%/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    printf "Error: ' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'system cnfiguration directory \\"%%s\\" is not a repository!\\n" "$SYSCONFIG"\n ' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '   exit 1\nfi\n\nif ! [ "$UID" = "0" ]; then\n    echo "Error: root is required!' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '"\n    exit 1\nfi\n\n[ ${SYSCONFIG_SECURE:-0} -eq 1 ] && mount -o rw,remount /\n' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '[ -e "/etc/profile.d/proxy.sh" ] && source "/etc/profile.d/proxy.sh" 2> /dev/nul' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 'l\n\nsh -c "cd ${SYSCONFIG}; git pull -q"\n\nsyslink\n\nif [ ${SYSCONFIG_SECURE:' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf '-0} -eq 1 ]; then\n    mount -o ro,remount / 2> /dev/null || mount -Ro ro,remoun' >> "${SETUP_DIRECTORY}/bin/syspull"
    /usr/bin/printf 't /\nfi\n' >> "${SETUP_DIRECTORY}/bin/syspull"

    # Create file "/bin/syspush"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSCONFI' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'G" ]; then\n    echo "Error: system configuration directory not found!"\n    exi' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 't 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf '\''Error: system configurat' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'ion directory "%%s" does not exist!\\n'\'' "$SYSCONFIG"\n    exit 1\nfi\n\nSYSCO' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'NFIG=${SYSCONFIG%%/}\nif ! [ -d "${SYSCONFIG}/.git" ]; then\n    printf "Error: ' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'system cnfiguration directory \\"%%s\\" is not a repository!\\n" "$SYSCONFIG"\n ' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '   exit 1\nfi\n\nif ! [ "$UID" = "0" ]; then\n    echo "Error: root is required!' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '"\n    exit 1\nfi\n\n[ ${SYSCONFIG_SECURE:-0} -eq 1 ] && mount -o rw,remount /\n' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf '[ -e "/etc/profile.d/proxy.sh" ] && source "/etc/profile.d/proxy.sh" 2> /dev/nul' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'l\n\nsh -c "cd ${SYSCONFIG}; git add -A .; [ -n \\"\\$(git status --porcelain=v1' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf ')\\" ] && git commit -m '\''syspush'\''; git push -q"\n\nsyslink\n\nif [ ${SYSCO' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'NFIG_SECURE:-0} -eq 1 ]; then\n    mount -o ro,remount / 2> /dev/null || mount -' >> "${SETUP_DIRECTORY}/bin/syspush"
    /usr/bin/printf 'Ro ro,remount /\nfi\n' >> "${SETUP_DIRECTORY}/bin/syspush"

    # Create file "/bin/sysupdate"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '#!/usr/bin/bash\n\nif ! [ "$UID" = "0" ]; then\n    echo "Error: root is require' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'd!"\n    exit 1\nfi\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -z "$SYSC' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'ONFIG" ]; then\n    echo "Error: system configuration directory not found!"\n   ' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf ' exit 1\nfi\nif ! [ -d "$SYSCONFIG" ]; then\n    printf '\''Error: system config' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'uration directory "%%s" does not exist!\\n'\'' "$SYSCONFIG"\n    exit 1\nfi\n\n[' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf ' ${SYSCONFIG_SECURE:-0} -eq 1 ] && mount -o rw,remount /\n[ -e "/etc/profile.d/p' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'roxy.sh" ] && source "/etc/profile.d/proxy.sh"\n\nif [ "$1" == "--auto" ]; then\n' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '    if [ "$2" == "--download" ]; then\n        pacman -Syuw --noconfirm\n       ' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf ' exit 0\n    fi\n    env SYSUPDATE=1 pacman -Syu --noconfirm\nelse\n    env SYSU' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'PDATE=1 pacman -Syu\nfi\n\n[ ${SYSCONFIG_SECURE:-0} -eq 1 ] && mount -o rw,remou' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'nt /\n[ -e "/etc/sysupdate.d/prelink.sh" ] && source "/etc/sysupdate.d/prelink.s' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'h"\n\nsyslink\n\n[ -e "/etc/sysupdate.d/postlink.sh" ] && source "/etc/sysupdate' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf '.d/postlink.sh"\nif [ ${SYSCONFIG_SECURE:-0} -eq 1 ]; then\n    mount -o ro,remo' >> "${SETUP_DIRECTORY}/bin/sysupdate"
    /usr/bin/printf 'unt / 2> /dev/null || mount -Ro ro,remount /\nfi\n' >> "${SETUP_DIRECTORY}/bin/sysupdate"

    # Create file "/etc/locale.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf 'LANG=en_US.UTF-8\nLC_TIME="en_US.UTF-8"\nLC_NAME="en_US.UTF-8"\nLC_CTYPE="en_US.' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf 'UTF-8"\nLC_PAPER="en_US.UTF-8"\nLC_NUMERIC="en_US.UTF-8"\nLC_COLLATE="en_US.UTF-' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '8"\nLC_ADDRESS="en_US.UTF-8"\nLC_MONETARY="en_US.UTF-8"\nLC_MESSAGES="en_US.UTF-' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '8"\nLC_TELEPHONE="en_US.UTF-8"\nLC_MEASUREMENT="en_US.UTF-8"\nLC_IDENTIFICATION=' >> "${SETUP_DIRECTORY}/etc/locale.conf"
    /usr/bin/printf '"en_US.UTF-8"\n' >> "${SETUP_DIRECTORY}/etc/locale.conf"

    # Create file "/etc/locale.gen"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/locale.gen"
    /usr/bin/printf 'en_US.UTF-8 UTF-8\nen_US       ISO-8859-1\n' >> "${SETUP_DIRECTORY}/etc/locale.gen"

    # Create file "/etc/login.defs"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '# Currently not used.\n# YESCRYPT_COST_FACTOR    5\n\nUMASK                   00' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '27\nMAIL_DIR                /var/spool/mail\nMOTD_FILE\nHOME_MODE               ' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '0700\nFAIL_DELAY              3\nCREATE_HOME             no\nNONEXISTENT        ' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '     /nonexistent\nDEFAULT_HOME            yes\nFORCE_SHADOW            yes\nCHF' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'N_RESTRICT           rwh\nENCRYPT_METHOD          YESCRYPT\nHUSHLOGIN_FILE      ' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '    .config/hushlogin\nUSERGROUPS_ENAB         yes\nHMAC_CRYPTO_ALGO        SHA5' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '12\nLOG_UNKFAIL_ENAB        no\nMAX_MEMBERS_PER_GROUP   0\nGRANT_AUX_GROUP_SUBID' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'S  yes\n\nENV_PATH                PATH=/usr/local/sbin:/usr/local/bin:/usr/bin\n' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'ENV_SUPATH              PATH=/usr/local/sbin:/usr/bin\n\nTTYPERM                ' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf ' 0620\nTTYGROUP                tty\n\nPASS_MAX_DAYS           99999\nPASS_MIN_DA' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'YS           0\nPASS_WARN_AGE           14\n\nLOGIN_RETRIES           5\nLOGIN_T' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'IMEOUT           120\n\nUID_MIN                 1000\nUID_MAX                 60' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '000\n\nGID_MIN                 1000\nGID_MAX                 60000\n\nSYS_UID_MI' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'N             500\nSYS_UID_MAX             999\nSUB_UID_MIN             100000\n' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'SUB_UID_MAX             600100000\nSUB_UID_COUNT           65536\n\nSYS_GID_MIN ' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf '            500\nSYS_GID_MAX             999\nSUB_GID_MIN             100000\nSU' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'B_GID_MAX             600100000\nSUB_GID_COUNT           65536\n\nSHA_CRYPT_MIN_' >> "${SETUP_DIRECTORY}/etc/login.defs"
    /usr/bin/printf 'ROUNDS    5000\nSHA_CRYPT_MAX_ROUNDS    5000\n' >> "${SETUP_DIRECTORY}/etc/login.defs"

    # Create file "/etc/logrotate.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf 'start       0\nweekly      0\nrotate      3\ninclude     /etc/logrotate.d\ntaboo' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf 'ext    + .pacorig .pacnew .pacsave\ndateformat  -%%y%%m%%d\n\ncreate\nnomail\nda' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf 'teext\nnoolddir\ncompress\nmissingok\nnotifempty\n\n/var/log/wtmp {\n    monthly' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf '\n    missingok\n\n    create  0664 root utmp\n    rotate  1\n    minsize 1M\n}\n' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf '/var/log/btmp {\n    monthly\n    missingok\n\n    create  0600 root utmp\n    r' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"
    /usr/bin/printf 'otate  1\n}\n' >> "${SETUP_DIRECTORY}/etc/logrotate.conf"

    # Create file "/etc/modprobe.d/pcspkr.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"
    /usr/bin/printf 'blacklist pcspkr\n' >> "${SETUP_DIRECTORY}/etc/modprobe.d/pcspkr.conf"

    # Create file "/etc/nftables.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'table inet filter {\n    chain base {\n        iif lo                           ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '                       accept\n\n        ip  saddr 127.0.0.1 ip  daddr 127.0.0.1' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '                 accept\n        ip6 saddr ::1       ip6 daddr ::1              ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '         accept\n\n        ip frag-off & 0x1fff != 0                            ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '   drop\n        ip frag-off & 0x1fff != 0 limit rate 10/minute  counter accept\n' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '\n        icmpv6  type {\n            nd-neighbor-advert,\n            nd-neighb' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'or-solicit\n        }                                                       acce' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'pt\n\n        ip saddr {\n            224.0.0.0/8,\n            255.255.255.255/' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '32\n        }                                                       drop\n      ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '  ip daddr {\n            0.0.0.0,\n            224.0.0.0/8,\n            255.25' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '5.255.255/32\n        }                                                       dr' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'op\n\n        fib daddr type {\n            anycast,\n            broadcast,\n  ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '          multicast\n        }                                                  ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '     drop\n\n        ct state invalid                                        dro' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'p\n        ct state related,established                    counter accept\n    }' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '\n    chain input {\n        type    filter hook input priority filter\n        ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'policy  drop\n\n        icmp    type echo-reply limit rate 1/second     counter ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'accept\n        icmpv6  type echo-reply limit rate 1/second     counter accept\n' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '        icmpv6  type {\n            time-exceeded,\n            packet-too-big,\n' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '            nd-router-advert,\n            parameter-problem,\n            nd-ro' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'uter-solicit,\n            destination-unreachable\n        }                   ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '                                    accept\n        icmpv6  type {\n            ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'mld-listener-done,\n            mld-listener-query,\n            mld-listener-re' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'port,\n            mld2-listener-report\n        }                       ip6 sad' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'dr fe80::/10             accept\n\n        tcp     dport 22                     ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '           counter accept\n\n        jump    base\n    }\n    chain output {\n  ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '      type    filter hook output priority filter\n        policy  drop\n\n      ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '  jump    base\n\n        icmp    type echo-request limit rate 1/second         ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '  accept\n        icmpv6  type echo-request limit rate 1/second           accept' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '\n\n        tcp     dport { 80, 3306 } ip daddr 127.0.0.1           accept\n\n  ' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf '      udp     dport { 53, 67, 68, 123 }                       accept\n        tc' >> "${SETUP_DIRECTORY}/etc/nftables.conf"
    /usr/bin/printf 'p     dport { 53, 80, 443, 587, 853, 11371 }          accept\n    }\n}\n' >> "${SETUP_DIRECTORY}/etc/nftables.conf"

    # Create file "/etc/nsswitch.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'passwd:     files systemd\ngroup:      files systemd\nshadow:     files systemd\n' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'gshadow:    files systemd\n\npublickey:  files\n\nhosts:      files myhostname r' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf 'esolve dns\nnetworks:   files\n\nprotocols:  files\nservices:   files\nethers:  ' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"
    /usr/bin/printf '   files\nrpc:        files\n\nnetgroup:   files\n' >> "${SETUP_DIRECTORY}/etc/nsswitch.conf"

    # Create file "/etc/pacman.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '[options]\nDBPath              = /var/lib/pacman\nGPGDir              = /etc/pac' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'man.d/gnupg\nRootDir             = /\nHookDir             = /etc/pacman.d/hooks\n' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'LogFile             = /var/log/pacman.log\nHoldPkg             = pacman glibc\nC' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'acheDir            = /var/cache/pacman/pkg\nSigLevel            = Required Datab' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'aseOptional\nCleanMethod         = KeepInstalled\nArchitecture        = auto\nPa' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'rallelDownloads   = 5\nLocalFileSigLevel   = Optional\n\nNoExtract           = u' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'sr/share/locale/* usr/share/X11/locale/*/* usr/share/i18n/locales/* opt/google/c' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'hrome/locales/* !usr/share/X11/locale/C/*\nNoExtract           = !usr/share/X11/' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'locale/compose.dir !usr/share/X11/locale/iso8859-1/*\nNoExtract           = !*lo' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'cale*/en*/* !usr/share/*locale*/locale.*\nNoExtract           = !usr/share/*loca' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'les/en_?? !usr/share/*locales/i18n* !usr/share/*locales/iso*\nNoExtract         ' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '  = usr/share/i18n/charmaps/* !usr/share/i18n/charmaps/UTF-8.gz !usr/share/i18n/' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'charmaps/ANSI_X3.4-1968.gz !usr/share/i18n/charmaps/ISO-8859-1.gz\nNoExtract    ' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '       = !usr/share/*locales/trans*\nNoExtract           = !usr/share/*locales/C' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf ' !usr/share/*locales/POSIX\nNoExtract           = usr/share/vim/vim*/lang/*\nNoE' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'xtract           = usr/share/gtk-doc/html/*\nNoExtract           = usr/share/doc' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf '/HTML/*\nNoExtract           = usr/share/help/* !usr/share/help/C/*\n\nVerbosePk' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'gLists\n\n[core]\nInclude             = /etc/pacman.d/mirrorlist\n[extra]\nInclu' >> "${SETUP_DIRECTORY}/etc/pacman.conf"
    /usr/bin/printf 'de             = /etc/pacman.d/mirrorlist\n' >> "${SETUP_DIRECTORY}/etc/pacman.conf"

    # Create file "/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf '[Trigger]\nType        = Path\nTarget      = usr/lib/modules/*/vmlinuz\nTarget  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf '    = usr/lib/initcpio/*\nTarget      = usr/lib/firmware/*\nTarget      = usr/sr' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf 'c/*/dkms.conf\nOperation   = Remove\nOperation   = Install\nOperation   = Upgrad' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf 'e\n\n[Trigger]\nType        = Package\nTarget      = linux\nTarget      = linux-' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf '*\nTarget      = systemd\nTarget      = intel-ucode\nTarget      = amd-ucode\nTa' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf 'rget      = mkinitcpio\nTarget      = mkinitcpio-git\nTarget      = mkinitcpio-b' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf 'usybox\nOperation   = Remove\nOperation   = Install\nOperation   = Upgrade\n\n[A' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf 'ction]\nWhen        = PreTransaction\nExec        = /usr/bin/mount -o remount,rw' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"
    /usr/bin/printf ' /boot\nDescription = Mounting /boot as read/write..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/00-boot.hook"

    # Create file "/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = pacman-mirrorlist\nOperation   =' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf ' Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bin/bash' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf ' -c "env XDG_CACHE_HOME=/var/cache/pacman reflector --protocol https --latest 30' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf ' --number 20 --sort rate --country '\''United States'\'' --save /var/cache/pacma' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf 'n/mirrorlist; rm -f /etc/pacman.d/mirrorlist.pacnew 2> /dev/null"\nDepends     =' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf ' reflector\nDescription = Updating pacman-mirrorlist with reflector and removing' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"
    /usr/bin/printf ' pacnew..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/y0-mirrors.hook"

    # Create file "/etc/pacman.d/hooks/z0-orphans.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z0-orphans.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z0-orphans.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z0-orphans.hook"
    /usr/bin/printf 'n/bash -c "pacman -Qtdq || echo '\''No orphans found.'\''"\nDescription = Findin' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z0-orphans.hook"
    /usr/bin/printf 'g orphan packages..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z0-orphans.hook"

    # Create file "/etc/pacman.d/hooks/z1-cache.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z1-cache.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z1-cache.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z1-cache.hook"
    /usr/bin/printf 'n/bash -c "paccache -rk4; paccache -ruk0"\nDescription = Removing old cached pac' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z1-cache.hook"
    /usr/bin/printf 'kages..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/z1-cache.hook"

    # Create file "/etc/pacman.d/hooks/za-findpac.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-findpac.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-findpac.hook"
    /usr/bin/printf 'on   = Upgrade\n\n[Action]\nWhen        = PostTransaction\nExec        = /usr/bi' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-findpac.hook"
    /usr/bin/printf 'n/find /etc -xdev -type f -name *.pac* -ls\nDescription = Looking for *.pac* fil' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-findpac.hook"
    /usr/bin/printf 'es..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-findpac.hook"

    # Create file "/etc/pacman.d/hooks/za-fixperms.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-fixperms.hook"
    /usr/bin/printf '[Trigger]\nType        = Package\nTarget      = *\nOperation   = Remove\nOperati' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-fixperms.hook"
    /usr/bin/printf 'on   = Install\nOperation   = Upgrade\n\n[Action]\nWhen        = PostTransaction' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-fixperms.hook"
    /usr/bin/printf '\nExec        = /usr/bin/bash -c "[ ${SYSUPDATE:-0} -eq 0 ] && syslink || exit 0' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-fixperms.hook"
    /usr/bin/printf '"\nDescription = Fixing permissions for system files..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/za-fixperms.hook"

    # Create file "/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf '[Trigger]\nType        = Path\nTarget      = usr/lib/modules/*/vmlinuz\nTarget  ' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf '    = usr/lib/initcpio/*\nTarget      = usr/lib/firmware/*\nTarget      = usr/sr' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'c/*/dkms.conf\nOperation   = Remove\nOperation   = Install\nOperation   = Upgrad' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'e\n\n[Trigger]\nType        = Package\nTarget      = linux\nTarget      = linux-' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf '*\nTarget      = systemd\nTarget      = intel-ucode\nTarget      = amd-ucode\nTa' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'rget      = mkinitcpio\nTarget      = mkinitcpio-git\nTarget      = mkinitcpio-b' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'usybox\nOperation   = Remove\nOperation   = Install\nOperation   = Upgrade\n\n[A' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'ction]\nWhen        = PostTransaction\nExec        = /usr/bin/mount -ro remount,' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"
    /usr/bin/printf 'ro /boot\nDescription = Mounting /boot as read only..\n' >> "${SETUP_DIRECTORY}/etc/pacman.d/hooks/zz-boot.hook"

    # Create file "/etc/profile.d/alias.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nexport EDITOR="nano"\n\nalias nano="nano -SLlwxiE --tabsize=4' >> "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"
    /usr/bin/printf '"\n' >> "${SETUP_DIRECTORY}/etc/profile.d/alias.sh"

    # Create file "/etc/profile.d/history.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/history.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nexport HISTSIZE=500\nexport HISTFILESIZE=0\nexport HISTFILE="' >> "${SETUP_DIRECTORY}/etc/profile.d/history.sh"
    /usr/bin/printf '/dev/null"\n\nexport LESSKEY="/etc/sysless"\nexport LESSHISTFILE="/dev/null"\n' >> "${SETUP_DIRECTORY}/etc/profile.d/history.sh"

    # Create file "/etc/profile.d/umask.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\numask 0027\n' >> "${SETUP_DIRECTORY}/etc/profile.d/umask.sh"

    # Create file "/etc/profile.d/z_system_status.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nstatus_repo() {\n    if ! source "/etc/sysconfig.conf" 2> /de' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'v/null; then\n        return 0\n    fi\n    if [ -z "$SYSCONFIG" ]; then\n      ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '  return 0\n    fi\n    if ! [ -d "$SYSCONFIG" ]; then\n        return 0\n    fi' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '\n    SYSCONFIG=${SYSCONFIG%%/}\n    if ! [ -d "${SYSCONFIG}/.git" ]; then\n    ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '    return 0\n    fi\n    if [ -n "$(sh -c "cd ${SYSCONFIG}; git status -s")" ];' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' then\n        printf '\''# Config:\\tSync needed, use "syspush"\\n'\''\n    els' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'e\n        printf "# Config:\\tUp-to-Date\\n"\n    fi\n}\nstatus_storage() {\n  ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '  echo "# Storage:"\n    df -h | grep -v "tmpfs" | grep -E '\''/dev/|/opt/|/mnt/' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ''\'' | sort -r | awk '\''{print ""$1" "$5" ("$3"/"$2")"}'\'' | sort | column -t ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '| awk '\''{print "#     "$0}'\''\n}\nstatus_network() {\n    echo "# Interface A' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'ddresses:"\n    for i in $(ip addr | grep "inet" | grep -vE "::1|127.0.0.1|link"' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' | awk '\''{print $2}'\'' | awk -F'\''/'\'' '\''{print $1}'\''); do\n        pri' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'ntf "#     %%s\\n" "$i"\n    done\n}\nstatus_services() {\n    printf "# Network' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ':\\t%%s Established, " "$(netstat -panut 2> /dev/null | grep -c "ESTABLISHED")"\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '    printf "%%s Listening\\n" "$(netstat -panut 2> /dev/null | grep -c "LISTEN")' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '"\n    printf "# Services:\\t%%s Running, " "$(systemctl --state=active --no-leg' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'end --no-pager | grep ".service" | grep -c "running")"\n    printf "%%s Failed, ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '" "$(systemctl --state=failed --no-legend --no-pager | grep -c ".service")"\n   ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ' printf "%%s Timers\\n" "$(systemctl --all --no-legend --no-pager | grep -c ".ti' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'mer")"\n}\n\nif [[ $- != *i* ]] || [ -n "$SSH_CLIENT" ]; then\n    printf "#####' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '#########################################################\\n"\n    status_storag' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'e\n    status_network\n    printf "# Uptime:\\t%%s\\n" "$(uptime --pretty | sed ' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf ''\''s/up //g'\'')"\n    printf "# Kernel:\\t%%s\\n" "$(uname -r)"\n    status_re' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf 'po\n    status_services\n    printf "###########################################' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"
    /usr/bin/printf '###################\\n"\nfi\n' >> "${SETUP_DIRECTORY}/etc/profile.d/z_system_status.sh"

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
    /usr/bin/printf 'entials       no\n    KbdInteractiveAuthentication    yes\n    ChallengeResponse' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"
    /usr/bin/printf 'Authentication yes\n' >> "${SETUP_DIRECTORY}/etc/ssh/ssh_config"

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
    /usr/bin/printf '         any\nListenAddress                   0.0.0.0\nListenAddress            ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '       ::\nKexAlgorithms                   curve25519-sha256@libssh.org,diffie-h' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'ellman-group-exchange-sha256\nLoginGraceTime                  1m\nPermitRootLogi' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'n                 yes # prohibit-password\nAllowTcpForwarding              no\nA' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'uthorizedKeysFile              .ssh/authorized_keys\nClientAliveCountMax        ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '     0\nClientAliveInterval             600\nIgnoreUserKnownHosts            no\n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'PermitEmptyPasswords            no\nAllowAgentForwarding            no\nPubkeyAu' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'thentication            yes\nAuthenticationMethods           publickey password ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '# publickey\nPasswordAuthentication          yes # no\nKerberosAuthentication   ' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf '       no\nHostbasedAuthentication         no\nKbdInteractiveAuthentication    n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"
    /usr/bin/printf 'o\nChallengeResponseAuthentication no\n' >> "${SETUP_DIRECTORY}/etc/ssh/sshd_config"

    # Create file "/etc/syscheck.d/cache.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nrm "/etc/.updated" 2> /dev/null\nrm "/etc/.pwd.lock" 2> /dev/' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'null\n\nlinkcheck "/etc/ld.so.cache" "/var/cache/ld.so.cache"\nlinkcheck "/etc/p' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'acman.d/gnupg" "/var/db/pacman/gnupg"\nlinkcheck "/etc/pacman.d/mirrorlist" "/va' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'r/cache/pacman/mirrorlist"\n\nchmod 0644 "/var/cache/ld.so.cache"\nchown root:ro' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'ot "/var/cache/ld.so.cache"\n\nchmod -R 0750 "/var/cache/pacman/pkg"\nchmod 0640' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf ' /var/cache/pacman/pkg/*\nchown -R root:root "/var/cache/pacman/pkg"\n\nchmod 07' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf '55 "/var/lib/pacman/sync"\nchmod 0644 /var/lib/pacman/sync/*\nchown -R root:root' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf ' "/var/lib/pacman/sync"\n\nchmod -R 0755 "/var/lib/pacman/local"\nchown -R root:' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'root "/var/lib/pacman/local"\nfind "/var/lib/pacman" -type f -exec chmod 0644 {}' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf ' \\;\n\nchmod 0700 "/var/cache/ldconfig"\nchown -R root:root "/var/cache/ldconfi' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"
    /usr/bin/printf 'g"\n' >> "${SETUP_DIRECTORY}/etc/syscheck.d/cache.sh"

    # Create file "/etc/syscheck.d/lesskey.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/syscheck.d/lesskey.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nlinkcheck "/etc/syslesskey" "/etc/sysless"\nlinkcheck "/usr/l' >> "${SETUP_DIRECTORY}/etc/syscheck.d/lesskey.sh"
    /usr/bin/printf 'ocal/etc/syslesskey" "/etc/sysless"\n\nchmod 0444 "/etc/sysless"\nchmod 0444 "/e' >> "${SETUP_DIRECTORY}/etc/syscheck.d/lesskey.sh"
    /usr/bin/printf 'tc/syslesskey"\nchmod 0444 "/usr/local/etc/syslesskey"\n' >> "${SETUP_DIRECTORY}/etc/syscheck.d/lesskey.sh"

    # Create file "/etc/syscheck.d/z_git.sh"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf '#!/usr/bin/bash\n\nsource "/etc/sysconfig.conf" 2> /dev/null\nif [ -n "$SYSCONFI' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf 'G" ]; then\n    if [ -d "$SYSCONFIG" ]; then\n        if [ -d "${SYSCONFIG}/.git' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf '" ]; then\n            chmod 0750 "$SYSCONFIG"/.git/hooks/*\n            bash -c' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf ' "cd ${SYSCONFIG}; git status -s" 2> /dev/null\n        fi\n    else\n        pr' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf 'intf '\''Error: system configuration directory "%%s" does not exist!\\n'\'' "$SY' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf 'SCONFIG"\n    fi\nelse\n    echo "Error: system configuration directory not foun' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"
    /usr/bin/printf 'd!"\nfi\n' >> "${SETUP_DIRECTORY}/etc/syscheck.d/z_git.sh"

    # Create file "/etc/sysctl.d/kernel.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'fs.file-max                     = 372925\nkernel.sysrq                    = 16\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'vm.swappiness                   = 10\nfs.suid_dumpable                = 0\nfs.pr' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'otected_fifos              = 1\nfs.protected_regular            = 1\nkernel.kptr' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf '_restrict            = 2\nkernel.dmesg_restrict           = 1\nfs.protected_syml' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'inks           = 1\nfs.protected_hardlinks          = 1\nkernel.yama.ptrace_scop' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'e        = 3\nkernel.kexec_load_disabled      = 1\nfs.inotify.max_user_watches  ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf '   = 16777215\nfs.inotify.max_queued_events    = 32767\nvm.dirty_writeback_centi' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"
    /usr/bin/printf 'secs    = 1500\nfs.inotify.max_user_instances   = 4096\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/kernel.conf"

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
    /usr/bin/printf '      = 2\nnet.ipv4.tcp_congestion_control             = bbr\nnet.ipv4.conf.all.' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'send_redirects            = 0\nnet.ipv6.conf.all.accept_redirects          = 0\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'net.ipv4.conf.all.accept_redirects          = 0\nnet.ipv4.tcp_slow_start_after_i' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf 'dle          = 0\nnet.ipv4.icmp_echo_ignore_broadcasts        = 1\nnet.ipv4.conf' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '.default.send_redirects        = 0\nnet.ipv4.conf.default.accept_redirects      ' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '= 0\nnet.ipv6.conf.default.accept_redirects      = 0\nnet.ipv4.icmp_ignore_bogus' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"
    /usr/bin/printf '_error_responses  = 1\n' >> "${SETUP_DIRECTORY}/etc/sysctl.d/network.conf"

    # Create file "/etc/sysless"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/sysless"
    /usr/bin/printf '\x00\x4D\x2B\x47\x63\x00\x00\x65\x00\x00\x76\x34\x00\x4C\x45\x53\x53\x00\x81\x2D' >> "${SETUP_DIRECTORY}/etc/sysless"
    /usr/bin/printf '\x69\x20\x2D\x52\x00\x4C\x45\x53\x53\x48\x49\x53\x54\x53\x49\x5A\x45\x00\x81\x30' >> "${SETUP_DIRECTORY}/etc/sysless"
    /usr/bin/printf '\x00\x4C\x45\x53\x53\x48\x49\x53\x54\x46\x49\x4C\x45\x00\x81\x2F\x64\x65\x76\x2F' >> "${SETUP_DIRECTORY}/etc/sysless"
    /usr/bin/printf '\x6E\x75\x6C\x6C\x00\x78\x45\x6E\x64' >> "${SETUP_DIRECTORY}/etc/sysless"

    # Create file "/etc/systemd/coredump.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"
    /usr/bin/printf '[Coredump]\nStorage = none\n' >> "${SETUP_DIRECTORY}/etc/systemd/coredump.conf"

    # Create file "/etc/systemd/homed.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/homed.conf"
    /usr/bin/printf '[Home]\nDefaultStorage          = directory\nDefaultFileSystemType   = btrfs\n' >> "${SETUP_DIRECTORY}/etc/systemd/homed.conf"

    # Create file "/etc/systemd/journald.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf '[Journal]\nSeal                = yes\nAudit               = on\nStorage         ' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf '    = persistent\nReadKMsg            = yes\nCompress            = yes\nSplitMod' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf 'e           = uid\nMaxFileSec          = 1day\nSystemMaxUse        = 256M\nMaxLe' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf 'velStore       = info\nForwardToSyslog     = no\nMaxRetentionSec     = 14day\nSy' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"
    /usr/bin/printf 'stemMaxFileSize   = 32M\n' >> "${SETUP_DIRECTORY}/etc/systemd/journald.conf"

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
    /usr/bin/printf '[Network]\nSpeedMeter          = no\nManageForeignRoutes = yes\n\n[DHCPv4]\nDUID' >> "${SETUP_DIRECTORY}/etc/systemd/networkd.conf"
    /usr/bin/printf 'Type            = vendor\n\n[DHCPv6]\nDUIDType            = vendor\n' >> "${SETUP_DIRECTORY}/etc/systemd/networkd.conf"

    # Create file "/etc/systemd/pstore.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/pstore.conf"
    /usr/bin/printf '[PStore]\nStorage = none\n' >> "${SETUP_DIRECTORY}/etc/systemd/pstore.conf"

    # Create file "/etc/systemd/resolved.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf '[Resolve]\nCache                       = yes\nLLMNR                       = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'DNSSEC                      = allow-downgrade\n# Domains                     = e' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf 'xample.com\nDNSOverTLS                  = no\nFallbackDNS                 = 127.' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf '0.0.1\n# FallbackDNS                 = 1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf ':4700:4700::1001\nReadEtcHosts                = yes\nMulticastDNS               ' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"
    /usr/bin/printf ' = no\nDNSStubListener             = no\nResolveUnicastSingleLabel   = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/resolved.conf"

    # Create file "/etc/systemd/sleep.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"
    /usr/bin/printf '[Sleep]\nAllowSuspend                = no\nAllowHibernation            = no\nAll' >> "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"
    /usr/bin/printf 'owHybridSleep            = no\nAllowSuspendThenHibernate   = no\n' >> "${SETUP_DIRECTORY}/etc/systemd/sleep.conf"

    # Create file "/etc/systemd/system.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '[Manager]\nLogTime                         = no\nLogColor                       ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf ' = yes\nDumpCore                        = no\nLogLevel                        = ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'warning\nLogTarget                       = journal-or-kmsg\nShowStatus          ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '            = auto\nNUMAPolicy                      = default\nCrashShell       ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '               = no\nCrashAction                     = freeze\nLogLocation      ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '               = no\nProtectSystem                   = auto\nCrashChangeVT      ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '             = no\nNoNewPrivileges                 = no\nDefaultTasksMax        ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '         = 15%%\nDefaultOOMPolicy                = stop\nStatusUnitFormat       ' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '         = description\nKExecWatchdogSec                = off\nDefaultRestartSec' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf '               = 100ms\nDefaultLimitNOFILE              = 1024:524288\nRuntimeWa' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'tchdogSec              = 0\nShutdownWatchdogSec             = 0\nDefaultIOAccoun' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'ting             = no\nDefaultIPAccounting             = no\nDefaultStandardErro' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'r            = inherit\nDefaultCPUAccounting            = no\nDefaultTimeoutStop' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'Sec           = 30s\nDefaultStandardOutput           = journal\nCtrlAltDelBurstA' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'ction           = reboot-force\nDefaultTimeoutStartSec          = 30s\nDefaultSt' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'artLimitBurst          = 5\nDefaultTasksAccounting          = yes\nDefaultTimerA' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'ccuracySec         = 1min\nDefaultMemoryAccounting         = yes\nDefaultBlockIO' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"
    /usr/bin/printf 'Accounting        = no\nDefaultStartLimitIntervalSec    = 10s\n' >> "${SETUP_DIRECTORY}/etc/systemd/system.conf"

    # Create file "/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"
    /usr/bin/printf '[Service]\nExecStart =\nExecStart = -/usr/bin/archlinux-keyring-wkd-sync\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/archlinux-keyring-wkd-sync.service.d/override.conf"

    # Create file "/etc/systemd/system/ldconfig.service.d/override.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/ldconfig.service.d/override.conf"
    /usr/bin/printf '[Service]\nExecStart =\nExecStart = /sbin/ldconfig -XC /var/cache/ld.so.cache\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/ldconfig.service.d/override.conf"

    # Create file "/etc/systemd/system/reflector.service"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '[Unit]\nAfter                   = network-online.target systemd-resolved.service' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '\nRequires                = network-online.target systemd-resolved.service\nDesc' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'ription             = Pacman Mirrorlist Update\n\n[Service]\nType               ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '     = simple\nExecStart               = /usr/bin/reflector --protocol https --l' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'atest 30 --number 20 --sort rate --country '\''United States'\'' --save /var/cac' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'he/pacman/mirrorlist\nPrivateTmp              = true\nEnvironment             = ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'XDG_CACHE_HOME=/var/cache/pacman\nKeyringMode             = private\nProtectHome' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '             = false\nProtectClock            = true\nPrivateUsers            = ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'true\nProtectSystem           = strict\nReadWritePaths          = /var/cache/pac' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'man\nPrivateDevices          = true\nNoNewPrivileges         = true\nLockPersona' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'lity         = true\nRestrictRealtime        = true\nRestrictSUIDSGID        = t' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'rue\nProtectKernelLogs       = true\nRestrictNamespaces      = true\nProtectCont' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'rolGroups    = true\nProtectKernelModules    = true\nProtectKernelTunables   = t' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf 'rue\nRestrictAddressFamilies = AF_INET AF_INET6\n\n[Install]\nRequiredBy        ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"
    /usr/bin/printf '      = multi-user.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.service"

    # Create file "/etc/systemd/system/reflector.timer"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf '[Unit]\nDescription         = Pacman Mirrorlist Update\n\n[Timer]\nOnCalendar   ' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf '       = weekly\nPersistent          = true\nRandomizedDelaySec  = 12h\n\n[Insta' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"
    /usr/bin/printf 'll]\nWantedBy            = timers.target\n' >> "${SETUP_DIRECTORY}/etc/systemd/system/reflector.timer"

    # Create file "/etc/systemd/timesyncd.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    /usr/bin/printf '[Time]\nNTP                 = time.nist.gov time-a-g.nist.gov time-b-g.nist.gov\n' >> "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"
    /usr/bin/printf 'RootDistanceMaxSec  = 30\n' >> "${SETUP_DIRECTORY}/etc/systemd/timesyncd.conf"

    # Create file "/etc/vconsole.conf"
    /usr/bin/printf "" > "${SETUP_DIRECTORY}/etc/vconsole.conf"
    /usr/bin/printf 'KEYMAP=us\n' >> "${SETUP_DIRECTORY}/etc/vconsole.conf"
}
setup_packages() {
    local _pkgs=(
          "base" "net-tools" "iptables-nft" "openssh"  "reflector" "linux-hardened" "man-db" "pacman-contrib" "git" "git-lfs"
          "which" "nano" "diffutils" "logrotate" "linux-firmware" "less" "intel-ucode" "amd-ucode"
        )
    if [ $_FS_TYPE -ge 2 ]; then
        _pkgs+=("lvm2")
    fi
    if [ $_FS_EFI -eq 1 ]; then
        _pkgs+=("efibootmgr")
    else
        _pkgs+=("grub")
    fi
    if fs_is_any "xfs"; then
        _pkgs+=("xfsprogs")
    fi
    if fs_is_any "ext4"; then
        _pkgs+=("e2fsprogs")
    fi
    if fs_is_any "btrfs"; then
        _pkgs+=("btrfs-progs")
    fi
    log "Installing Packages to root.."
    if ! pacstrap "${SETUP_ROOT}" ${_pkgs[@]}; then
        bail "\x1b[0m\x1b[1mpacstrap\x1b[0m\x1b[31m returned a non-zero error code"
    fi
    log "Package install complete!"
}

set -uo pipefail

trap cleanup 1 2 3 6

setup_init
setup_disk
setup_packages
setup_config
setup_chroot
sync

if [ -n "$SETUP_SCRIPT" ]; then
    source "$SETUP_SCRIPT"
fi

sync
log "Install complete!"
trap - 1 2 3 6

if [ $SETUP_REBOOT -eq 1 ]; then
    log "Hit \x1b[0m\x1b[1mCTRL+C\x1b[0m\x1b[32m to stop reboot and unmount of disks!"
    log "Rebooting in \x1b[0m\x1b[1m5\x1b[0m\x1b[32m seconds.."
    sleep 3
    log "Rebooting in \x1b[0m\x1b[1m2\x1b[0m\x1b[32m seconds.."
    sleep 2
    log "Unmounting and rebooting!"
    cleanup 1
    systemctl reboot
else
    log "Please unmount all disks before restarting!"
fi
