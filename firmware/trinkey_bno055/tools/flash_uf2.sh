#!/usr/bin/env bash
set -euo pipefail

UF2_FILE="$1"
MOUNT_POINT="/run/media/kretu/RPI-RP2"

if [ ! -f "$UF2_FILE" ]; then
    echo "UF2 file not found: $UF2_FILE"
    exit 1
fi

if [ ! -d "$MOUNT_POINT" ]; then
    echo "RPI-RP2 bootloader drive not found at:"
    echo "  $MOUNT_POINT"
    echo
    echo "Currently mounted devices:"
    lsblk -o NAME,LABEL,MOUNTPOINTS,FSTYPE
    exit 1
fi

echo "Copying:"
echo "  $UF2_FILE"
echo "to:"
echo "  $MOUNT_POINT"

cp "$UF2_FILE" "$MOUNT_POINT/"
sync

echo "Flash copy complete. Board should reboot."