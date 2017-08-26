#!/usr/bin/bash

DEBUG=1

INSTALL_LOG=""
INSTALL_DISK=""
INSTALL_RETURN=""
INSTALL_NETWORK=()
INSTALL_HOSTNAME="archlinux"

install_yes()
{
  tmp_empty_true=0
  printf "[?] $1 [" 1>&3
  if [[ $# -eq 2 && "$2" == "1" ]]; then
    tmp_empty_true=1
    printf "Y/n]? " 1>&3
  else
    printf "y/N]? " 1>&3
  fi
  read tmp_q_check
  if [[ $tmp_empty_true -eq 1 && -z "$tmp_q_check" ]]; then
    return 0
  fi
  if [[ "$tmp_q_check" == "Y" || "$tmp_q_check" == "y" ]]; then
    return 0
  fi
  return 1
}
install_log()
{
  if [ $# -le 0 ]; then
    return 1
  fi
  tmp_log_date=$(date +"%m%d%y-%H%M%S")
  if [ -x $INSTALL_LOG ]; then
    INSTALL_LOG="/tmp/arch-install-$tmp_log_date.log"
    exec 3>&1 1>>${INSTALL_LOG} 2>&1
    touch $INSTALL_LOG
  fi
  if [ $# -ge 2 ]; then
    if ! [[ "$1" == "D" ]]; then
      printf "[$1] $2\n" 1>&3
    fi
    printf "($tmp_log_date) [$1] $2\n" >> $INSTALL_LOG
  else
    printf "[+] $1\n" 1>&3
    printf "($tmp_log_date) [+] $1\n" >> $INSTALL_LOG
  fi
  return 0
}
install_bail()
{
  install_log "E" "$1"
  install_log "E" "Unfixable error occurred! Exiting!"
  install_log "E" "Log file is at \"$INSTALL_LOG\""
  install_log "E" "Please reboot and retry..."
  exit 1
}
install_prep()
{
  #exec 3>&1 1>>${INSTALL_LOG} 2>&1
  ping -c 1 google.com &> /dev/null
  if [ $? -ne 0 ]; then
    install_bail "No internet connection! How did you get this script?"
  fi
  pacman -Syy | tee /dev/fd/3
  pacman -S archlinux-keyring --noconfirm | tee /dev/fd/3
}
install_copy()
{
  install_log "Starting package download.."
  tmp_packages=( "base" "net-tools" "openssh" "reflector" )
  if [[ "$INSTALL_FS" == "btrfs" ]]; then
    tmp_packages+=("btrfs-progs")
  fi
  if [[ ! -z "$INSTALL_EFI" && $INSTALL_EFI -eq 1 ]]; then
    tmp_packages+=("efibootmgr")
  else
    tmp_packages+=("grub")
  fi
  if [[ ! -z "$INSTALL_PACAUR" && $INSTALL_PACAUR -eq 1 ]]; then
    tmp_packages+=("binutils")
    tmp_packages+=("make")
    tmp_packages+=("gcc")
    tmp_packages+=("fakeroot")
    tmp_packages+=("expac")
    tmp_packages+=("yajl")
    tmp_packages+=("git")
  fi
  install_log "Installing Packages.."
  pacstrap /mnt ${tmp_packages[@]} | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "pacstrap returned a non-zero error code!"
  fi
  install_log "Package install finished!"
}
install_disk()
{
  if install_yes "Autodetect disk" 1; then
    install_log "D" "Attempting to find the default disk.."
    if [ -b "/dev/sda" ]; then
      INSTALL_DISK="/dev/sda"
    elif [ -b "/dev/vda" ]; then
      INSTALL_DISK="/dev/vda"
    elif [ -b "/dev/xda" ]; then
      INSTALL_DISK="/dev/xda"
    fi
    if [ ! -z "$INSTALL_DISK" ]; then
      install_log "Selected $INSTALL_DISK.."
    else
      install_log "E" "Could not find a disk!"
    fi
  fi
  if [ -z "$INSTALL_DISK" ]; then
    lsblk 2> /dev/null
    while [ -z "$INSTALL_DISK"  ]; do
      if install_question "Select a disk to use (no partitions)"; then
        if [ -b $INSTALL_RETURN ]; then
          INSTALL_DISK="$INSTALL_RETURN"
        fi
      fi
    done
    install_log "Selected $INSTALL_DISK.."
  fi
  install_log "Formatting disk.."
  if [[ ! -z "$INSTALL_EFI" && $INSTALL_EFI -eq 1 ]]; then
    printf "g\nn\n\n\n+200M\nt\n1\nn\n\n\n\nw" | fdisk $INSTALL_DISK | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "fdisk returned a non-zero error code!"
    fi
    partprobe | tee /dev/fd/3
    mkfs.fat -F32 -nEFI "${INSTALL_DISK}1" | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "mkfs.vfa returned a non-zero error code!"
    fi
  else
    printf "o\nn\n\n\n\n+200M\nt\nc\nn\n\n\n\n\nw" | fdisk $INSTALL_DISK | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "fdisk returned a non-zero error code!"
    fi
    partprobe | tee /dev/fd/3
    mkfs.fat "${INSTALL_DISK}1" | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "mkfs.fat returned a non-zero error code!"
    fi
  fi
  install_log "Creating LVM partitions.."
  pvcreate "${INSTALL_DISK}2" | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "pvcreate returned a non-zero error code!"
  fi
  vgcreate storage "${INSTALL_DISK}2" | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "vgcreate returned a non-zero error code!"
  fi
  lvcreate -n root storage -l 100%FREE --yes | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "lvcreate returned a non-zero error code!"
  fi
  case $INSTALL_FS in
    "xfs")
    mkfs.xfs -f -L root /dev/mapper/storage-root | tee /dev/fd/3
    ;;
    "btrfs")
    mkfs.btrfs -f -L root /dev/mapper/storage-root | tee /dev/fd/3
    ;;
    "ext4")
    mkfs.ext4 -F -L root /dev/mapper/storage-root | tee /dev/fd/3
    ;;
    *)
    mkfs.ext4 -F -L root /dev/mapper/storage-root | tee /dev/fd/3
    ;;
  esac
  if [ $? -ne 0 ]; then
    install_bail "mkfs returned a non-zero error code!"
  fi
  install_log "D" "Format complete.."
  if [[ ! -z "$INSTALL_FS_BTRFS_LZO" && $INSTALL_FS_BTRFS_LZO -eq 1 ]]; then
    mount -o compress=lzo /dev/mapper/storage-root /mnt | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "mount returned a non-zero error code!"
    fi
  else
    mount /dev/mapper/storage-root /mnt | tee /dev/fd/3
    if [ $? -ne 0 ]; then
      install_bail "mount returned a non-zero error code!"
    fi
  fi
  install_log "D" "Drive mounted to \"/mnt\""
  mkdir /mnt/boot 
  mount "${INSTALL_DISK}1" /mnt/boot | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "mount returned a non-zero error code!"
  fi
  install_log "Disks were mounted!"
}
install_setup()
{
  install_log "D" "Checking for EFI vars.."
  efibootmgr &> /dev/null
  if [ $? -eq 2 ]; then
    install_log "D" "This is not booted as EFI"
    if install_yes "Install as EFI boot?"; then
      INSTALL_EFI=1
      install_log "Installing as EFI.."
    fi
  else
    install_log "D" "Booted into a EFI system"
    if install_yes "This system is EFI, install as EFI boot?" 1; then
      INSTALL_EFI=1
      install_log "Installing as EFI.."
    fi
  fi
  if install_question "Set system hostname [$INSTALL_HOSTNAME]"; then
    INSTALL_HOSTNAME="$INSTALL_RETURN"
  fi
  install_log "Hostname will be \"$INSTALL_HOSTNAME\".."
  tmp_fs_correct=0
  while [ $tmp_fs_correct -eq 0 ]; do
    if install_question "Select root filesystem (btrfs/ext4/xfs)"; then
      case $INSTALL_RETURN in
        "ext4")
        INSTALL_FS="ext4"
        tmp_fs_correct=1
        ;;
        "xfs")
        INSTALL_FS="xfs"
        tmp_fs_correct=1
        ;;
        "btrfs")
        INSTALL_FS="btrfs"
        tmp_fs_correct=1
        ;;
        *)
        tmp_fs_correct=0
        ;;
      esac
    else
      INSTALL_FS="btrfs"
      tmp_fs_correct=1
    fi
  done
  install_log "Filesystem set to \"$INSTALL_FS\".."
  if [[ $INSTALL_FS == "btrfs" ]]; then
    if ! install_yes "Use LZO compression for BTRFS" 1; then
      INSTALL_FS_BTRFS_LZO=1
      install_log "D" "Selected lzo compression for btrfs.."
    fi
  fi
  if install_yes "Enable SSHd to start at boot" 1; then
    INSTALL_SSH=1
    install_log "D" "Selected sshd to start at boot.."
  fi
  if install_yes "Use hardened SSHd config files" 1; then
    INSTALL_HARD_SSH=1
    install_log "D" "Selected secured sshd configuration.."
  fi
  if install_question "Set the locale [en_US.UTF-8]"; then
    INSTALL_LOCALE="$INSTALL_RETURN"
  fi
  if install_yes "Install Pacaur package manager" 0; then
    INSTALL_PACAUR=1
    install_log "D" "Selected to install pacaur.."
  fi
  if install_yes "Change the default root password" 1; then
    tmp_passwd1=""
    tmp_passwd2=""
    while [[ -z "$tmp_passwd1" || "$tmp_passwd1" != "$tmp_passwd2" ]]; do
      if [[ ! -z "$tmp_passwd1" ]]; then
        printf "[!] Passwords did not match, try again..\n" 1>&3
      fi
      printf "[..] New Password (hidden): " 1>&3
      read -s tmp_passwd1
      printf "\n[..] Confirm (hidden): " 1>&3
      read -s tmp_passwd2
      printf "\n" 1>&3
    done
    INSTALL_PASSWD="$tmp_passwd1"
    install_log "Root password has been set.."
  else
    install_log "W" "Root password will default to \"archlinux\", please change it when possible!"
  fi
}
install_finish()
{
  install_log "*" "Install is finished!!"
  install_log "Will unmount and reboot in 5 seconds.."
  install_log "Press CTRL-C to exit and do any manual configurations before reboot.."
  sleep 3
  install_log "Rebooting in 2 seconds! Press CTRL-C to exit and do any manual configurations.."
  sleep 2
  umount /mnt/boot /mnt
  if [ $DEBUG -ne 1 ]; then
    reboot
  fi
}
install_question()
{
  printf "[?] $1? " 1>&3
  read tmp_q_check
  if [[ ! -z "$tmp_q_check" ]]; then
    INSTALL_RETURN="$tmp_q_check"
    if [ $# -eq 2 ]; then
      return 1
    fi
    return 0
  fi
  INSTALL_RETURN=""
  if [ $# -eq 2 ]; then
    return 0
  fi
  return 1
}
install_configure()
{
  install_log "Configuring system.."
  if [[ ! -z "$INSTALL_LOCALE" ]]; then
    printf "$INSTALL_LOCALE" > /mnt/etc/locale.gen
  else
    printf "en_US.UTF-8 UTF-8\n\nen_US ISO-8859-1" > /mnt/etc/locale.gen
  fi
  echo "$INSTALL_HOSTNAME" > /mnt/etc/hostname
  printf "[Time]\nNTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org\n" > /mnt/etc/systemd/timesyncd.conf
  install_log "Configuring network.."
  for tmp_nic_config in $INSTALL_NETWORK; do
    tmp_nic_name=$(echo $tmp_nic_config | awk -F, '{print $1}')
    tmp_nic_rename=$(echo $tmp_nic_config | awk -F, '{print $2}')
    tmp_nic_address4=$(echo $tmp_nic_config | awk -F, '{print $3}')
    tmp_nic_gateway4=$(echo $tmp_nic_config | awk -F, '{print $4}')
    tmp_nic_address6=$(echo $tmp_nic_config | awk -F, '{print $5}')
    tmp_nic_dns1=$(echo $tmp_nic_config | awk -F, '{print $6}')
    tmp_nic_dns2=$(echo $tmp_nic_config | awk -F, '{print $7}')
    tmp_nic="$tmp_nic_name"
    install_log "D" "Configuring Interface \"$tmp_nic\".."
    if [[ ! -z "$tmp_nic_rename" ]]; then
      tmp_nic="$tmp_nic_rename"
      tmp_nic_mac=$(ifconfig $tmp_nic_name | grep ether | awk '{print $2}')
      printf "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"$tmp_nic_mac\", NAME=\"$tmp_nic_rename\"\n" >> /mnt/etc/udev/rules.d/10-network.rules
    fi
    printf "[Match]\nName=$tmp_nic\n\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
    if [[ -z "$tmp_nic_address4" ]]; then
      printf "[Network]\nDHCP=yes\n\n[DHCP]\nUseDomains=yes\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
    else
      printf "[Network]\nAddress=$tmp_nic_address4\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
      if [[ ! -z "$tmp_nic_address6" ]]; then
        printf "Address=$tmp_nic_address6\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
      fi
      printf "DNS=$tmp_nic_dns1\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
      if [[ ! -z "$tmp_nic_dns2" ]]; then
        printf "DNS=$tmp_nic_dns2\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
      fi
      printf "\n[Route]\nGateway=$tmp_nic_gateway4\n" >> "/mnt/etc/systemd/network/$tmp_nic.network"
    fi
  done
  install_log "D" "Configuring files.."
  if [ -z "$INSTALL_EFI" ]; then
    sed -i -e 's/part_gpt part_msdos/part_gpt lvm part_msdos/g' /mnt/etc/default/grub
  fi
  if [[ $INSTALL_FS == "btrfs" ]]; then
    sed -i -e 's/block filesystems/block lvm2 btrfs filesystems/g' /mnt/etc/mkinitcpio.conf
  else
    sed -i -e 's/block filesystems/block lvm2 filesystems/g' /mnt/etc/mkinitcpio.conf
  fi
  rm -f /mnt/etc/localtime
  rm -f /mnt/etc/resolv.conf
  mkdir -p /mnt/etc/pacman.d/hooks
  printf "[Trigger]\nOperation = Upgrade\nType = Package\nTarget = pacman-mirrorlist\n\n[Action]\nDescription = Updating pacman-mirrorlist with reflector and removing pacnew...\n" > /mnt/etc/pacman.d/hooks/mirrorupgrade.hook
  printf "When = PostTransaction\nDepends = reflector\n" >> /mnt/etc/pacman.d/hooks/mirrorupgrade.hook
  printf "Exec = /usr/bin/env sh -c \"reflector --country 'United States' --latest 200 --age 24 --sort rate --save /etc/pacman.d/mirrorlist; if [[ -f /etc/pacman.d/mirrorlist.pacnew ]]; then rm /etc/pacman.d/mirrorlist.pacnew; fi\"\n" >> /mnt/etc/pacman.d/hooks/mirrorupgrade.hook
  printf "[Unit]\nDescription=Pacman mirrorlist update\nRequires=network-online.target\nAfter=network-online.target\n\n" > /mnt/etc/systemd/system/reflector.service
  printf "[Service]\nType=oneshot\nExecStart=/usr/bin/reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist\n\n" >> /mnt/etc/systemd/system/reflector.service
  printf "[Install]\nRequiredBy=multi-user.target\n" >> /mnt/etc/systemd/system/reflector.service
  printf "[Unit]\nDescription=Run reflector weekly\n\n[Timer]\nOnCalendar=weekly\nRandomizedDelaySec=12h\nPersistent=true\n\n" > /mnt/etc/systemd/system/reflector.timer
  printf "[Install]\nWantedBy=timers.target\n" >> /mnt/etc/systemd/system/reflector.timer
  mkdir -p /mnt/etc/systemd/system/sockets.target.wants
  mkdir -p /mnt/etc/systemd/system/timers.target.wants
  mkdir -p /mnt/etc/systemd/system/network-online.target.wants
  if [[ ! -z "$INSTALL_PACAUR" && $INSTALL_PACAUR -eq 1 ]]; then
    # TODO: Add this later!
    mkdir -p /mnt/tmp/cower
    mkdir -p /mnt/tmp/pacaur
    curl -o /tmp/cower/PKGBUILD https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=cower
    curl -o /tmp/pacaur/PKGBUILD https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pacaur
  fi
  if [[ ! -z "$INSTALL_HARD_SSH" && $INSTALL_HARD_SSH -eq 1 ]]; then
    rm -f /mnt/etc/ssh/*key*
    rm -f /mnt/etc/ssh/*_config
    awk '$5 > 2000' /mnt/etc/ssh/moduli > /mnt/etc/ssh/moduli
  	ssh-keygen -t ed25519 -f /mnt/etc/ssh/ssh_host_ed25519_key -N "" < /dev/null
  	ssh-keygen -t rsa -b 4096 -f /mnt/etc/ssh/ssh_host_rsa_key -N "" < /dev/null
  	printf "Port 22\nAddressFamily any\nListenAddress 0.0.0.0\nListenAddress ::\nProtocol 2\nHostKey /etc/ssh/ssh_host_rsa_key\nHostKey /etc/ssh/ssh_host_ed25519_key\n" > /mnt/etc/ssh/sshd_config
    printf "PubkeyAuthentication yes\nPasswordAuthentication yes\nPermitEmptyPasswords no\nKerberosAuthentication no\nChallengeResponseAuthentication no\n" >> /mnt/etc/ssh/sshd_config
    printf "ServerKeyBits 4096\nPermitRootLogin yes\nCiphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr\n" >> /mnt/etc/ssh/sshd_config
    printf "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-ripemd160-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,hmac-ripemd160,umac-128@openssh.com\n" >> /mnt/etc/ssh/sshd_config
    printf "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256\nAuthorizedKeysFile .ssh/authorized_keys\nRhostsRSAAuthentication no\nHostbasedAuthentication no\n" >> /mnt/etc/ssh/sshd_config
    printf "IgnoreUserKnownHosts no\nIgnoreRhosts yes\nAllowAgentForwarding no\nAllowTcpForwarding no\nGatewayPorts no\nPermitTTY yes\nPrintMotd yes\nPrintLastLog yes\nTCPKeepAlive yes\n" >> /mnt/etc/ssh/sshd_config
    printf "LoginGraceTime 1m\nUsePrivilegeSeparation sandbox\nCompression no\nClientAliveInterval 3600\nClientAliveCountMax 0\nMaxStartups 10:30:100\nPermitTunnel no\nSubsystem sftp /usr/lib/ssh/sftp-server" >> /mnt/etc/ssh/sshd_config
    printf "Host *\n\tPasswordAuthentication yes\n\tChallengeResponseAuthentication yes\n\tPubkeyAuthentication yes\n" > /mnt/etc/ssh/ssh_config
    printf "\tHostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com,ssh-ed25519,ssh-rsa\n" >> /mnt/etc/ssh/ssh_config
    printf "\tKexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256\n" >> /mnt/etc/ssh/ssh_config
    printf "\tCiphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr\n" >> /mnt/etc/ssh/ssh_config
    printf "\tMACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-ripemd160-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,hmac-ripemd160,umac-128@openssh.com\n" >> /mnt/etc/ssh/ssh_config
    printf "\tUseRoaming no\n\tForwardAgent no\n\tForwardX11 no\n\tGSSAPIAuthentication no\n\tGSSAPIDelegateCredentials no\n\tHostbasedAuthentication no\n" >> /mnt/etc/ssh/ssh_config
    printf "\tStrictHostKeyChecking ask\n\tCheckHostIP yes\n\tBatchMode no\n\tAddressFamily any\n\tPort 22\n\tProtocol 2\n\tTunnel no\n" >> /mnt/etc/ssh/ssh_config
    printf "\tConnectTimeout 30\n\tPermitLocalCommand no\n\tHashKnownHosts yes\n\tIdentityFile ~/.ssh/id_ed25519\n\tIdentityFile ~/.ssh/id_rsa\n\tVisualHostKey yes" >> /mnt/etc/ssh/ssh_config
    chmod 400 /mnt/etc/ssh/*key*
    chmod 400 /mnt/etc/ssh/sshd_config
    chmod 444 /mnt/etc/ssh/ssh_config
  elif [[ ! -z "$INSTALL_SSH" && $INSTALL_SSH -eq 1 ]]; then
    sed -i -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /mnt/etc/ssh/sshd_config
  fi
  install_log "D" "Creating install script at \"/mnt/root/start.sh\".."
  printf "#!/bin/bash\n\n" > /mnt/root/start.sh
  printf "/usr/bin/locale-gen\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/share/zoneinfo/America/New_York /etc/localtime\n" >> /mnt/root/start.sh
  printf "/usr/bin/mkinitcpio -p linux\n" >> /mnt/root/start.sh
  if [[ ! -z "$INSTALL_PASSWD" ]]; then
    printf "printf '$INSTALL_PASSWD\\n$INSTALL_PASSWD' | passwd root\n" >> /mnt/root/start.sh
  else
    printf "printf 'archlinux\\narchlinux' | passwd root\n" >> /mnt/root/start.sh
  fi
  if [[ ! -z "$INSTALL_EFI" && $INSTALL_EFI -eq 1 ]]; then
    printf "bootctl install\n" >> /mnt/root/start.sh
  else
	printf "grub-install $INSTALL_DISK\n" >> /mnt/root/start.sh
	printf "grub-mkconfig -o /boot/grub/grub.cfg\n" >> /mnt/root/start.sh
	if [[ ! -z "$INSTALL_GRSEC" && $INSTALL_GRSEC -eq 1 ]]; then
	  printf "grub-set-default 1\n" >> /mnt/root/start.sh
	fi
  fi
  printf "/usr/bin/touch /run/systemd/resolve/resolv.conf &> /dev/null\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /etc/systemd/system/reflector.service /etc/systemd/system/multi-user.target.wants/reflector.service\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /etc/systemd/system/reflector.timer /etc/systemd/system/timers.target.wants/reflector.timer\n" >> /mnt/root/start.sh
  printf "/usr/bin/ln -s /usr/lib/systemd/system/systemd-networkd-wait-online.service /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service\n" >> /mnt/root/start.sh
  printf "/usr/bin/timedatectl set-ntp true\n" >> /mnt/root/start.sh
  printf "/usr/bin/reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist\n" >> /mnt/root/start.sh
  if [[ ! -z "$INSTALL_SSH" && $INSTALL_SSH -eq 1 ]]; then
    printf "/usr/bin/ln -s /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service\n" >> /mnt/root/start.sh
  fi
  printf "/usr/bin/update-ca-trust\n" >> /mnt/root/start.sh
  printf "exit\n" >> /mnt/root/start.sh
  chmod 755 /mnt/root/start.sh
  genfstab -U -p /mnt > /mnt/etc/fstab | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "genfstab returned a non-zero error code!"
  fi
  if [[ "$INSTALL_FS" != "xfs" ]]; then
    sed -i -e 's/relatime/noatime/g' /mnt/etc/fstab
  fi
  install_log "Starting chroot.."
  arch-chroot /mnt /root/start.sh | tee /dev/fd/3
  if [ $? -ne 0 ]; then
    install_bail "arch-chroot returned a non-zero error code!"
  fi
  install_log "Chroot finished!"
  if [[ ! -z "$INSTALL_EFI" && $INSTALL_EFI -eq 1 ]]; then
    install_log "Configuring EFI boot.."
    tmp_bootdisk=""
    tmp_options=""
    tmp_disklist=$(ls -al /dev/disk/by-uuid/ | awk '{print $9}' | grep '-')
    for tmp_disk in $tmp_disklist; do
      tmp_mount=$(cat /mnt/etc/fstab | grep "UUID=$tmp_disk" | grep "/" | awk '{print $2}')
      if [[ "$tmp_mount" == "/" && ${#tmp_mount} -eq 1 ]]; then
        tmp_bootdisk="$tmp_disk"
        tmp_options=$(cat /mnt/etc/fstab | grep "UUID=$tmp_disk" | grep "/" | awk '{print $4}' | sed 's/,/ /g')
      fi
    done
    if [ -z "$tmp_bootdisk" ]; then
      install_bail "Could not find the correct bootdisk!"
    else
      install_log "D" "Bootdisk is \"$tmp_bootdisk\".."
      if [[ ! -z "$INSTALL_GRSEC" && $INSTALL_GRSEC -eq 1 ]]; then
        printf "title\tArch Linux\nlinux\t/vmlinuz-linux-grsec\ninitrd\t/initramfs-linux-grsec.img\noptions\troot=UUID=$tmp_bootdisk $tmp_options\n" > /mnt/boot/loader/entries/arch.conf
      else
        printf "title\tArch Linux\nlinux\t/vmlinuz-linux\ninitrd\t/initramfs-linux.img\noptions\troot=UUID=$tmp_bootdisk $tmp_options\n" > /mnt/boot/loader/entries/arch.conf
      fi
    fi
  fi
  install_log "D" "Deleting install script.."
  rm -f /mnt/root/start.sh
}
install_network_setup()
{
  tmp_nics=$(ifconfig -a | grep flags | awk -F':' '{print $1}' | grep -v "lo")
  for tmp_nic in $tmp_nics; do install_network_nic_setup $tmp_nic; done
}
install_network_nic_setup()
{
  install_log "D" "Starting Interface setup for \"$1\".."
  if [ $# -ne 1 ]; then
    printf "install_network_nic_setup <nic>\n"
    return
  fi
  tmp_nic_name=$1
  if install_yes "($tmp_nic_name) Automatically setup interface" 1; then
    INSTALL_NETWORK+=("$tmp_nic_name,,,,,,")
  else
    tmp_nic_rename=$1
    tmp_nic_address4=""
    tmp_nic_address6=""
    tmp_nic_gateway4=""
    tmp_nic_dns1=""
    tmp_nic_dns2=""
    if install_question "($tmp_nic_name) Rename this interface"; then
      tmp_nic_rename="$INSTALL_RETURN"
    fi
    if install_yes "($tmp_nic_rename) Use DHCP for this interface" 1; then
      INSTALL_NETWORK+=("$tmp_nic_name,$tmp_nic_rename,,,,,")
      return 0
    else
      tmp_nic_cur_addr4=$(ip addr show dev $tmp_nic_name | grep inet | grep brd | awk '{print $2}')
      tmp_nic_cur_gateway=$(ip addr show dev $tmp_nic_name | grep inet | grep brd | awk '{print $4}')
      tmp_nic_cur_addr6=$(ip addr show dev $tmp_nic_name | grep inet6 | awk '{print $2}')
      if install_question "($tmp_nic_rename) IPv4 Address [$tmp_nic_cur_addr4]"; then
        tmp_nic_address4="$INSTALL_RETURN"
      else
        tmp_nic_address4="$tmp_nic_cur_addr4"
      fi
      if install_question "($tmp_nic_rename) IPv4 Gateway [$tmp_nic_cur_gateway]"; then
        tmp_nic_gateway4="$INSTALL_RETURN"
      else
        tmp_nic_gateway4="$tmp_nic_cur_gateway"
      fi
      if install_yes "($tmp_nic_rename) Add a static IPv6 address"; then 
        if install_question "($tmp_nic_rename) IPv6 Address [$tmp_nic_cur_addr6]"; then
          tmp_nic_address6="$INSTALL_RETURN"
        else
          tmp_nic_address6="$tmp_nic_cur_addr6"
        fi
      fi
      tmp_nic_dns_server=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
      tmp_nic_dns_server1=$(echo $tmp_nic_dns_server | awk -F' ' '{print $1}')
      if install_question "($tmp_nic_rename) Primary DNS Server [$tmp_nic_dns_server1]"; then
        tmp_nic_dns1="$INSTALL_RETURN"
      else
        tmp_nic_dns1="$tmp_nic_dns_server1"
      fi
      install_question "($tmp_nic_rename) Secondary DNS Server (Optional)"
      tmp_nic_dns2="$INSTALL_RETURN"
      INSTALL_NETWORK+=("$tmp_nic_name,$tmp_nic_rename,$tmp_nic_address4,$tmp_nic_gateway4,$tmp_nic_address6,$tmp_nic_dns1,$tmp_nic_dns2")
      return 0
    fi
  fi
  return 1
}

install_log "Starting ArchInstaller by iDigitalFlame.."
install_prep
install_setup
install_network_setup
install_disk
install_copy
install_configure
install_finish

