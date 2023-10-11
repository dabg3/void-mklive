#!/bin/bash
#
# mklive $ARCH -> lib $HOSTARCH 
# mklive $BASE_ARCH-> $IMAGEARCH

# Check for root permissions.
if [ "$(id -u)" -ne 0 ]; then
    echo "WARNING: root check disabled"
    #die "Must be run as root, exiting..."
fi

# lib.sh side-effect: 
#   * init $XBPS_REPOSITORY
#   * init $HOSTARCH
. ./lib.sh
. ./scripts/logging.sh


#readonly PROGNAME=$(basename "$0")

# array of directories to include in rootfs
declare -a INCLUDE_DIRS=()

while getopts "a:b:r:R:c:C:T:Kk:l:i:I:S:s:o:p:v:Vh" opt; do
    case $opt in
        a) IMAGEARCH="$OPTARG";;
        b) BASE_SYSTEM_PKG="$OPTARG";;
        r) XBPS_REPOSITORY="--repository=$OPTARG $XBPS_REPOSITORY";;
        R) ROOTDIR="$OPTARG";;
        c) XBPS_CACHEDIR="$OPTARG";;
        K) readonly KEEP_BUILDDIR=1;;
        k) KEYMAP="$OPTARG";;
        l) LOCALE="$OPTARG";;
        i) INITRAMFS_COMPRESSION="$OPTARG";;
        I) INCLUDE_DIRS+=("$OPTARG");;
        S) SERVICE_LIST="$SERVICE_LIST $OPTARG";;
        s) SQUASHFS_COMPRESSION="$OPTARG";;
        o) OUTPUT_FILE="$OPTARG";;
        p) PACKAGE_LIST="$PACKAGE_LIST $OPTARG";;
        C) BOOT_CMDLINE="$OPTARG";;
        T) BOOT_TITLE="$OPTARG";;
        v) LINUX_VERSION="$OPTARG";;
        V) version; exit 0;;
        *) usage;;
    esac
done
# reset OPTIND after getopts
# https://unix.stackexchange.com/questions/214141/explain-the-shell-command-shift-optind-1
shift "$((OPTIND - 1))"

# TODO: migrate
# Configure dracut to use overlayfs for the writable overlay.
BOOT_CMDLINE="$BOOT_CMDLINE rd.live.overlay.overlayfs=1 "

# Set defaults
# The colon builtin (:) ensures the variable result is not executed.
# := operator assigns value only if variable is undefined.
# https://stackoverflow.com/questions/2013547/assigning-default-values-to-shell-variables-with-a-single-command-in-bash
: ${IMAGEARCH:=$HOSTARCH}
: ${XBPS_CACHEDIR:="$(pwd -P)"/xbps-cachedir-${IMAGEARCH}}
: ${XBPS_HOST_CACHEDIR:="$(pwd -P)"/xbps-cachedir-${HOSTARCH}}
: ${ROOTDIR}:="$(pwd -P)"
: ${KEYMAP:=us}
: ${LOCALE:=en_US.UTF-8}
: ${INITRAMFS_COMPRESSION:=xz}
: ${SQUASHFS_COMPRESSION:=xz}
: ${BASE_SYSTEM_PKG:=base-system}
: ${BOOT_TITLE:="Void Linux"}
# internal
: ${SPLASH_IMAGE:=data/splash.png}
: ${XBPS_INSTALL_CMD:=xbps-install}
: ${XBPS_REMOVE_CMD:=xbps-remove}
: ${XBPS_QUERY_CMD:=xbps-query}
: ${XBPS_RINDEX_CMD:=xbps-rindex}
: ${XBPS_UHELPER_CMD:=xbps-uhelper}
: ${XBPS_RECONFIGURE_CMD:=xbps-reconfigure}

case $IMAGEARCH in
    x86_64*|i686*) ;;
    *) >&2 echo architecture $IMAGEARCH not supported by mklive.sh; exit 1;;
esac

BUILDDIR=$(mktemp --tmpdir="$ROOTDIR" -d)
BUILDDIR=$(readlink -f "$BUILDDIR")
echo $BUILDDIR
IMAGEDIR="$BUILDDIR/image"
ROOTFS="$IMAGEDIR/rootfs"
VOIDHOSTDIR="$BUILDDIR/void-host"
BOOT_DIR="$IMAGEDIR/boot"
ISOLINUX_DIR="$BOOT_DIR/isolinux"
SYSLINUX_DATADIR="$VOIDHOSTDIR/usr/lib/syslinux"
GRUB_DIR="$BOOT_DIR/grub"
GRUB_DATADIR="$VOIDHOSTDIR/usr/share/grub"
mkdir -p "$ROOTFS" "$VOIDHOSTDIR" "$ISOLINUX_DIR" "$GRUB_DIR"


print_step "Synchronizing XBPS repository data..."
copy_void_keys() {
    mkdir -p "$1"/var/db/xbps/keys
    cp keys/*.plist "$1"/var/db/xbps/keys
}
copy_void_keys "$ROOTFS"
copy_void_keys "$VOIDHOSTDIR"
XBPS_ARCH=$IMAGEARCH $XBPS_INSTALL_CMD -r "$ROOTFS" ${XBPS_REPOSITORY} -S
XBPS_ARCH=$HOSTARCH $XBPS_INSTALL_CMD -r "$VOIDHOSTDIR" ${XBPS_REPOSITORY} -S


# Get linux version for ISO
if [ -n "$LINUX_VERSION" ]; then
    if ! echo "$LINUX_VERSION" | grep "linux[0-9._]\+"; then
        die "-v option must be in format linux<version>"
    fi

    _linux_series="$LINUX_VERSION"
    PACKAGE_LIST="$PACKAGE_LIST $LINUX_VERSION" #here dracut gets into the system
else # Otherwise find latest stable version from linux meta-package
    _linux_series=$(XBPS_ARCH=$IMAGEARCH $XBPS_QUERY_CMD -r "$ROOTFS" ${XBPS_REPOSITORY:=-R} -x linux | grep 'linux[0-9._]\+')
fi

_kver=$(XBPS_ARCH=$IMAGEARCH $XBPS_QUERY_CMD -r "$ROOTFS" ${XBPS_REPOSITORY:=-R} -p pkgver ${_linux_series})
KERNELVERSION=$($XBPS_UHELPER_CMD getpkgversion ${_kver})

if [ "$?" -ne "0" ]; then
    die "Failed to find kernel package version"
fi

: ${OUTPUT_FILE:="void-live-${IMAGEARCH}-${KERNELVERSION}-$(date -u +%Y%m%d).iso"}


print_step "Installing software to generate the image: ${REQUIRED_PKGS} ..."
readonly REQUIRED_PKGS="base-files libgcc dash coreutils sed tar gawk syslinux grub-i386-efi grub-x86_64-efi memtest86+ squashfs-tools xorriso"
install_prereqs() {
    XBPS_ARCH=$HOSTARCH "$XBPS_INSTALL_CMD" -r "$VOIDHOSTDIR" ${XBPS_REPOSITORY} \
         -c "$XBPS_HOST_CACHEDIR" -y $REQUIRED_PKGS
    [ $? -ne 0 ] && die "Failed to install required software, exiting..."
}
install_prereqs


print_step "Installing void pkgs into the rootfs: ${PACKAGE_LIST} ..."
# Required packages in the image for a working system.
PACKAGE_LIST="$BASE_SYSTEM_PKG $PACKAGE_LIST"
readonly INITRAMFS_PKGS="binutils xz device-mapper dhclient openresolv"
install_packages() {
    XBPS_ARCH=$IMAGEARCH "${XBPS_INSTALL_CMD}" -r "$ROOTFS" \
        ${XBPS_REPOSITORY} -c "$XBPS_CACHEDIR" -yn $PACKAGE_LIST $INITRAMFS_PKGS
    [ $? -ne 0 ] && die "Missing required binary packages, exiting..."

    mount_pseudofs

    LANG=C XBPS_ARCH=$IMAGEARCH "${XBPS_INSTALL_CMD}" -U -r "$ROOTFS" \
        ${XBPS_REPOSITORY} -c "$XBPS_CACHEDIR" -y $PACKAGE_LIST $INITRAMFS_PKGS
    [ $? -ne 0 ] && die "Failed to install $PACKAGE_LIST"

    xbps-reconfigure -r "$ROOTFS" -f base-files >/dev/null 2>&1
    chroot "$ROOTFS" env -i xbps-reconfigure -f base-files

    # Enable choosen UTF-8 locale and generate it into the target rootfs.
    if [ -f "$ROOTFS"/etc/default/libc-locales ]; then
        sed -e "s/\#\(${LOCALE}.*\)/\1/g" -i "$ROOTFS"/etc/default/libc-locales
    fi
    chroot "$ROOTFS" env -i xbps-reconfigure -a

    # Cleanup and remove useless stuff.
    rm -rf "$ROOTFS"/var/cache/* "$ROOTFS"/run/* "$ROOTFS"/var/run/*
}
install_packages