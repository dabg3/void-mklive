#!/bin/sh

type getargbool >/dev/null 2>&1 || . /lib/dracut-lib.sh

# These functions pulled from void's excellent mklive.sh
VAI_info_msg() {
    printf "\033[1m%s\n\033[m" "$@"
}

VAI_print_step() {
    CURRENT_STEP=$((CURRENT_STEP+1))
    VAI_info_msg "[${CURRENT_STEP}/${STEP_COUNT}] $*"
}

# ----------------------- Install Functions ------------------------

VAI_welcome() {
    clear
    printf "=============================================================\n"
    printf "================ Void Linux Auto-Installer ==================\n"
    printf "=============================================================\n"
}

VAI_get_address() {
    mkdir -p /var/lib/dhclient

    # This will fork, but it means that over a slow link the DHCP
    # lease will still be maintained.  It also doesn't have a
    # hard-coded privsep user in it like dhcpcd.
    dhclient
}

VAI_partition_disk() {
    sfdisk -X gpt "${disk}" <<EOF
,$bootpartitionsize,U 
;
EOF
    disk_part1=$(lsblk $disk -nlp --output NAME | sed -n "2p")
    disk_part2=$(lsblk $disk -nlp --output NAME | sed -n "3p")
}

VAI_prepare_crypt_lvm() {
    cryptsetup luksFormat --batch-mode --type=luks1 $disk_part2
    cryptsetup open $disk_part2 crypt
    lvm vgcreate vg0 /dev/mapper/crypt
    lvm lvcreate --name swap -L ${swapsize}K vg0
    lvm lvcreate --name void -l +100%FREE vg0
}

VAI_format_disk() {
    # Make Filesystems
    mkfs.fat -n BOOT -F 32 $disk_part1
    mkfs.btrfs -L void /dev/mapper/vg0-void
    if [ "${swapsize}" -ne 0 ] ; then
        mkswap /dev/mapper/vg0-swap
    fi
}

VAI_mount_target() {
    # Mount targetfs
    mkdir $target
    mount -o rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60 /dev/mapper/vg0-void $target
    btrfs subvolume create $target/@
    btrfs subvolume create $target/@home
    btrfs subvolume create $target/@snapshots
    umount $target
    mount -o rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@ /dev/mapper/vg0-void $target
    mkdir $target/home
    mkdir $target/.snapshots
    mount -o rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@home /dev/mapper/vg0-void $target/home/
    mount -o rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@snapshots /dev/mapper/vg0-void $target/.snapshots/
    mkdir -p $target/boot/efi
    mount -o rw,noatime $disk_part1 $target/boot/efi/
    mkdir -p $target/var/cache
    btrfs subvolume create $target/var/cache/xbps
    btrfs subvolume create $target/var/tmp
    btrfs subvolume create $target/srv
}

VAI_install_xbps_keys() {
    mkdir -p "${target}/var/db/xbps/keys"
    cp /var/db/xbps/keys/* "${target}/var/db/xbps/keys"
}

VAI_install_base_system() {
    # Install a base system
    # temporary restoring original
    XBPS_ARCH="${XBPS_ARCH}" xbps-install -Sy -R "${xbpsrepository}" -r /mnt base-system btrfs-progs cryptsetup grub-x86_64-efi lvm2 dosfstools

    # Install additional packages
    if [  -n "${pkgs}" ] ; then
        # shellcheck disable=SC2086
        # TODO
        XBPS_ARCH="${XBPS_ARCH}" xbps-install -Sy -R "${xbpsrepository}" -r /mnt ${pkgs}
    fi
}

VAI_prepare_chroot() {
    # Mount dev, bind, proc, etc into chroot
    mount -t proc proc "${target}/proc"
    mount --rbind /sys "${target}/sys"
    mount --rbind /dev "${target}/dev"
}

VAI_configure_sudo() {
    # Give wheel sudo
    echo "%wheel ALL=(ALL:ALL) ALL" > "${target}/etc/sudoers.d/00-wheel"
    chmod 0440 "${target}/etc/sudoers.d/00-wheel"
}

VAI_correct_root_permissions() {
    chroot $target passwd root # prompt
    chroot "${target}" chown root:root /
    chroot "${target}" chmod 755 /
}

VAI_configure_hostname() {
    # Set the hostname
    echo "${hostname}" > "${target}/etc/hostname"
}

VAI_configure_rc_conf() {
    # Activate/Set various tokens
    sed -i "s:#HARDWARECLOCK:HARDWARECLOCK:" "${target}/etc/rc.conf"
    sed "/^.*TIMEZONE.*/c TIMEZONE=${timezone}" "${target}/etc/rc.conf"
    sed "/^.*KEYMAP.*/c KEYMAP=${keymap}" "${target}/etc/rc.conf"
}

VAI_add_user() {
    chroot "${target}" useradd -m -s /bin/bash -U -G wheel,users,audio,video,cdrom,input "${username}"
    if [ -z "${password}" ] ; then
        chroot "${target}" passwd "${username}"
    else
        # For reasons that remain unclear, this does not work in musl
        echo "${username}:${password}" | chpasswd -c SHA512 -R "${target}"
fi
}

VAI_configure_grub() {
    # Set hostonly TODO investigate effects
    # echo "hostonly=yes" > "${target}/etc/dracut.conf.d/hostonly.conf"
    cat <<EOF >> $target/etc/default/grub
GRUB_ENABLE_CRYPTODISK=y
EOF

    sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ rd.auto=1 cryptdevice=UUID=$LUKS_UUID:lvm:allow-discards&/" $target/etc/default/grub
    # Choose the newest kernel
    kernel_version="$(chroot "${target}" xbps-query linux | awk -F "[-_]" '/pkgver/ {print $2}')"
    kernel_release="$(chroot $target uname -r)"

    dd bs=512 count=4 if=/dev/urandom of=$target/boot/volume.key
    cryptsetup luksAddKey $disk_part2 $target/boot/volume.key
    chmod 000 $target/boot/volume.key
    chmod -R g-rwx,o-rwx $target/boot

    cat <<EOF >> $target/etc/crypttab
crypt $disk_part2 /boot/volume.key luks
EOF

    cat <<EOF >> $target/etc/dracut.conf.d/10-crypt.conf
install_items+=" /boot/volume.key /etc/crypttab "
EOF

    echo 'add_dracutmodules+=" crypt btrfs lvm resume "' >> $target/etc/dracut.conf
    echo 'tmpdir=/tmp' >> $target/etc/dracut.conf

    chroot "${target}" dracut --force --hostonly --kver "${kernel_release}"

    # Install grub
    mkdir $target/boot/grub
    chroot "${target}" grub-mkconfig -o /boot/grub/grub.cfg
    chroot "${target}" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void --boot-directory=/boot  --recheck
    chroot "${target}" xbps-reconfigure -f "linux${kernel_version}"

    # Correct the grub install
    chroot "${target}" update-grub
    ln -s $target/etc/sv/dhcpcd $target/etc/runit/runsvdir/default
    sed -i 's/issue_discards = 0/issue_discards = 1/' $target/etc/lvm/lvm.conf
}

VAI_configure_fstab() {
    # Grab UUIDs
    UEFI_UUID=$(blkid -s UUID -o value $disk_part1)
    LUKS_UUID=$(blkid -s UUID -o value $disk_part2)
    ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/vg0-void)
    SWAP_UUID=$(blkid -s UUID -o value /dev/mapper/vg0-swap)

    # Installl UUIDs into /etc/fstab
    cat <<EOF > $target/etc/fstab
UUID=$ROOT_UUID / btrfs rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@ 0 1
UUID=$ROOT_UUID /home btrfs rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs rw,noatime,ssd,compress=lzo,space_cache=v2,commit=60,subvol=@snapshots 0 2
UUID=$UEFI_UUID /boot/efi vfat defaults,noatime 0 2
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
EOF
    if [ "${swapsize}" -ne 0 ] ; then
        echo "UUID=$SWAP_UUID none swap defaults 0 1" >> "${target}/etc/fstab" 
    fi
}

VAI_configure_locale() {
    # Set the libc-locale iff glibc
    case "${XBPS_ARCH}" in
        *-musl)
            VAI_info_msg "Glibc locales are not supported on musl"
            ;;
        *)
            sed -i "/${libclocale}/s/#//" "${target}/etc/default/libc-locales"

            chroot "${target}" xbps-reconfigure -f glibc-locales
            ;;
    esac
    echo "LANG=${libclocale}" > $target/etc/locale.conf
}

VAI_end_action() {
    case $end_action in
        reboot)
            VAI_info_msg "Rebooting the system"
            sync
            umount -R "${target}"
            reboot -f
            ;;
        shutdown)
            VAI_info_msg "Shutting down the system"
            sync
            umount -R "${target}"
            poweroff -f
            ;;
        script)
            VAI_info_msg "Running user provided script"
            xbps-uhelper fetch "${end_script}>/script"
            chmod +x /script
            target=${target} xbpsrepository=${xbpsrepository} /script
            ;;
        func)
            VAI_info_msg "Running user provided function"
            end_function
            ;;
    esac
}

VAI_configure_autoinstall() {
    # -------------------------- Setup defaults ---------------------------
    bootpartitionsize="500M"
    # select first non-root-mounted disk 
    disk="$(lsblk -ipo NAME,TYPE,MOUNTPOINT | awk '{if ($2=="disk") {disks[$1]=0; last=$1} if ($3=="/") {disks[last]++}} END {for (a in disks) {if(disks[a] == 0){print a; break}}}')"
    hostname="$(ip -4 -o -r a | awk -F'[ ./]' '{x=$7} END {print x}')"
    # XXX: Set a manual swapsize here if the default doesn't fit your use case
    swapsize="$(awk -F"\n" '/MemTotal/ {split($0, b, " "); print b[2] }' /proc/meminfo)";
    target="/mnt"
    timezone="America/Chicago"
    keymap="us"
    libclocale="en_US.UTF-8"
    username="voidlinux"
    end_action="shutdown"
    end_script="/bin/true"

    XBPS_ARCH="$(xbps-uhelper arch)"
    case $XBPS_ARCH in
        *-musl)
            xbpsrepository="https://repo-default.voidlinux.org/current/musl"
            ;;
        *)
            xbpsrepository="https://repo-default.voidlinux.org/current"
            ;;
    esac

    # --------------- Pull config URL out of kernel cmdline -------------------------
    set +e
    if getargbool 0 autourl ; then
        set -e
        xbps-uhelper fetch "$(getarg autourl)>/etc/autoinstall.cfg"

    else
        set -e
        mv /etc/autoinstall.default /etc/autoinstall.cfg
    fi

    # Read in the resulting config file which we got via some method
    if [ -f /etc/autoinstall.cfg ] ; then
        VAI_info_msg "Reading configuration file"
        . ./etc/autoinstall.cfg
    fi

    # Bail out if we didn't get a usable disk
    if [ -z "$disk" ] ; then
        die "No valid disk!"
    fi
}

VAI_main() {
    CURRENT_STEP=0
    STEP_COUNT=16

    VAI_welcome

    VAI_print_step "Bring up the network"
    VAI_get_address

    VAI_print_step "Configuring installer"
    VAI_configure_autoinstall

    VAI_print_step "Configuring disk"
    VAI_partition_disk
    VAI_prepare_crypt_lvm #TODO: conditionality 
    VAI_format_disk

    VAI_print_step "Mounting the target filesystems"
    VAI_mount_target

    VAI_print_step "Installing XBPS keys"
    VAI_install_xbps_keys

    VAI_print_step "Installing the base system"
    VAI_install_base_system

    VAI_print_step "Granting sudo to default user"
    VAI_configure_sudo

    VAI_print_step "Setting hostname"
    VAI_configure_hostname

    VAI_print_step "Configure rc.conf"
    VAI_configure_rc_conf

    VAI_print_step "Preparing the chroot"
    VAI_prepare_chroot

    VAI_print_step "Fix ownership of /"
    VAI_correct_root_permissions

    VAI_print_step "Adding default user"
    VAI_add_user

    VAI_print_step "Configuring GRUB"
    VAI_configure_grub

    VAI_print_step "Configuring /etc/fstab"
    VAI_configure_fstab

    VAI_print_step "Configuring libc-locales"
    VAI_configure_locale

    VAI_print_step "Performing end-action"
    VAI_end_action
}

# If we are using the autoinstaller, launch it
if getargbool 0 auto  ; then
    set -e
    VAI_main
    # Very important to release this before returning to dracut code
    set +e
fi

