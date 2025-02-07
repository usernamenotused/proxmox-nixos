#!/usr/bin/env bash

set -e

# Check if the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    # If not, re-execute the script with sudo
    echo "This script requires root privileges. Elevating..."
    sudo bash "$0" "$@"
    exit $?
fi

# set the Hard Disk device by id
DEVICE="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"

PARTITIONS=$(lsblk "$DEVICE" --output NAME --noheadings --raw | wc -l)
if [ "$PARTITIONS" -gt 1 ]; then
    echo "The device $DEVICE has $PARTITIONS partitions. Please use the partition device instead."
else
    echo "Partitioning $DEVICE"
    parted $DEVICE -- mklabel gpt
    parted $DEVICE -- mkpart root ext4 512MB -8GB
    parted $DEVICE -- mkpart swap linux-swap -8GB 100%
    parted $DEVICE -- mkpart ESP fat32 1MB 512MB
    parted $DEVICE -- set 3 esp on
    mkfs.ext4 -L nixos "${DEVICE}-part1"
    mkswap  -L swap "${DEVICE}-part2"
    swapon "${DEVICE}-part2"
    mkfs.fat -F 32 -n boot "${DEVICE}-part3"
    
    echo "Done"

fi
echo "Mounting $DEVICE"
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot
echo "Done"
echo "Generating NixOS configuration"
nixos-generate-config --root /mnt
echo "Done"
echo "editing configuration.nix"
# download the configuration.nix file from github
curl -s -L https://raw.githubusercontent.com/usernamenotused/proxmox-nixos/main/configuration.nix > /mnt/etc/nixos/configuration.nix
echo "Done"
echo "Installing NixOS"
nixos-install
echo "Done"
echo "Rebooting"
reboot

