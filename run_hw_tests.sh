#!/bin/bash
# Hardware-simulation tests using a loop device (runs in CI or locally).
# Simulates the microSD card tests run on real hardware (Raspberry Pi).
# Requires: losetup, sfdisk, mkfs.vfat, mkfs.ext4, sudo
set -euo pipefail

ZZ="${ZZ:-$(realpath "$(dirname "$0")")/zig-out/bin/zz}"
IMG="$(mktemp /tmp/zz-disk-XXXXXX.img)"
MNT_ROOT="$(mktemp -d /tmp/zz-mnt-XXXXXX)"
LOOP=""

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }

cleanup() {
    [ -n "$LOOP" ] && sudo umount "${LOOP}p2" 2>/dev/null || true
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP"  2>/dev/null || true
    sudo rm -f "$IMG"
    rm -rf "$MNT_ROOT"
    sudo rm -f /tmp/zz_ci_*.bin
}
trap cleanup EXIT

echo "=== zz loop-device tests (simulated block device) ==="
echo ""

# ── Setup ──────────────────────────────────────────────────────────────────────
echo "Setting up 64MB disk image..."

# Create blank image
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none

# Partition: 8MB FAT32 (p1) + rest ext4 (p2)
sudo sfdisk "$IMG" --quiet << 'EOF'
label: dos
unit: sectors
1M,8M,c
9M,,83
EOF

# Attach as loop device with partition scanning
LOOP=$(sudo losetup --find --show --partscan "$IMG")

# Format
sudo mkfs.vfat -n bootfs "${LOOP}p1" >/dev/null 2>&1
sudo mkfs.ext4 -L rootfs -q "${LOOP}p2"

# Populate p2 with a few real files so tests have meaningful content
sudo mkdir -p "$MNT_ROOT"
sudo mount "${LOOP}p2" "$MNT_ROOT"
sudo mkdir -p "$MNT_ROOT/etc" "$MNT_ROOT/usr/bin"
sudo cp /etc/passwd "$MNT_ROOT/etc/passwd"
sudo cp "$(which ls)" "$MNT_ROOT/usr/bin/ls"
sudo umount "$MNT_ROOT"

echo "  Loop device: $LOOP  ($(sudo sfdisk -l "$IMG" 2>/dev/null | grep -c "^${IMG}" || true) partitions)"
echo ""

# ── Test 1: MBR signature ──────────────────────────────────────────────────────
echo "=== TEST 1: MBR read (512 bytes, raw device) ==="
sudo "$ZZ" if="$LOOP" of=/tmp/zz_ci_mbr.bin bs=512 count=1 status=noxfer 2>/tmp/zz_ci_mbr_err
last_two=$(od -An -tx1 /tmp/zz_ci_mbr.bin | tail -1 | awk '{print $(NF-1), $NF}')
if [ "$last_two" = "55 aa" ]; then
    pass "MBR signature 55 aa present"
else
    fail "MBR signature" "got: $last_two"
fi
echo ""

# ── Test 2: Raw read matches dd ────────────────────────────────────────────────
echo "=== TEST 2: 1MB raw read matches dd ==="
sudo dd if="$LOOP" of=/tmp/zz_ci_ref.bin bs=1M count=1 status=none 2>/dev/null
sudo "$ZZ" if="$LOOP" of=/tmp/zz_ci_zz.bin  bs=1M count=1 status=none 2>/dev/null
if cmp -s /tmp/zz_ci_ref.bin /tmp/zz_ci_zz.bin; then
    pass "1MB raw read byte-identical to dd"
else
    fail "1MB raw read" "output differs from dd"
fi
echo ""

# ── Test 3: File copy from mounted partition ───────────────────────────────────
echo "=== TEST 3: File copy from mounted ext4 partition ==="
sudo mount -o ro "${LOOP}p2" "$MNT_ROOT"

sudo dd if="$MNT_ROOT/etc/passwd" of=/tmp/zz_ci_passwd_dd.bin bs=512 status=none 2>/dev/null
sudo "$ZZ" if="$MNT_ROOT/etc/passwd" of=/tmp/zz_ci_passwd_zz.bin bs=512 status=none 2>/dev/null
if cmp -s /tmp/zz_ci_passwd_dd.bin /tmp/zz_ci_passwd_zz.bin; then
    pass "passwd copy identical to dd"
else
    fail "passwd copy" "output differs from dd"
fi

sudo dd if="$MNT_ROOT/usr/bin/ls" of=/tmp/zz_ci_ls_dd.bin bs=4096 status=none 2>/dev/null
sudo "$ZZ" if="$MNT_ROOT/usr/bin/ls" of=/tmp/zz_ci_ls_zz.bin bs=4096 status=none 2>/dev/null
if cmp -s /tmp/zz_ci_ls_dd.bin /tmp/zz_ci_ls_zz.bin; then
    pass "binary (ls) copy identical to dd"
else
    fail "binary copy" "output differs from dd"
fi
echo ""

# ── Test 4: Partial read (skip + count) ───────────────────────────────────────
echo "=== TEST 4: Partial read with skip=2 count=4 bs=64 ==="
sudo dd if="$MNT_ROOT/etc/passwd" bs=64 skip=2 count=4 \
    status=noxfer of=/tmp/zz_ci_partial_dd.bin 2>/tmp/zz_ci_stats_dd
sudo "$ZZ" if="$MNT_ROOT/etc/passwd" bs=64 skip=2 count=4 \
    status=noxfer of=/tmp/zz_ci_partial_zz.bin 2>/tmp/zz_ci_stats_zz

if cmp -s /tmp/zz_ci_partial_dd.bin /tmp/zz_ci_partial_zz.bin; then
    pass "partial read output identical to dd"
else
    fail "partial read output" "differs from dd"
fi
if diff -q /tmp/zz_ci_stats_dd /tmp/zz_ci_stats_zz >/dev/null 2>&1; then
    pass "partial read stats identical to dd"
else
    fail "partial read stats" "$(diff /tmp/zz_ci_stats_dd /tmp/zz_ci_stats_zz)"
fi

sudo umount "$MNT_ROOT"
echo ""

# ── Test 5: Partition image SHA256 matches dd ──────────────────────────────────
echo "=== TEST 5: 4MB partition image SHA256 matches dd ==="
sudo "$ZZ" if="${LOOP}p2" of=/tmp/zz_ci_img_zz.bin bs=1M count=4 status=none 2>/dev/null
sudo dd  if="${LOOP}p2" of=/tmp/zz_ci_img_dd.bin bs=1M count=4 status=none 2>/dev/null
SHA_ZZ=$(sha256sum /tmp/zz_ci_img_zz.bin | cut -d' ' -f1)
SHA_DD=$(sha256sum /tmp/zz_ci_img_dd.bin | cut -d' ' -f1)
if [ "$SHA_ZZ" = "$SHA_DD" ]; then
    pass "4MB image SHA256 matches dd ($SHA_ZZ)"
else
    fail "4MB image SHA256" "zz=$SHA_ZZ dd=$SHA_DD"
fi
echo ""

# ── Test 6: Round-trip copy ────────────────────────────────────────────────────
echo "=== TEST 6: Round-trip file copy ==="
"$ZZ" if=/tmp/zz_ci_img_zz.bin of=/tmp/zz_ci_roundtrip.bin bs=4096 status=none 2>/dev/null
if cmp -s /tmp/zz_ci_img_zz.bin /tmp/zz_ci_roundtrip.bin; then
    pass "round-trip copy identical"
else
    fail "round-trip copy" "output differs from source"
fi
echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ $FAIL -eq 0 ]
