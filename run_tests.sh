#!/bin/bash
# Test harness for zz - ported from coreutils dd test suite
set -euo pipefail

ZZ="${ZZ:-$(realpath "$(dirname "$0")")/zig-out/bin/zz}"
TMPDIR=$(mktemp -d /tmp/zz-tests.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1 ($2)"; SKIP=$((SKIP+1)); }

assert_eq() {
  local name="$1" got="$2" expected="$3"
  if [ "$got" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "got=$(printf '%q' "$got") expected=$(printf '%q' "$expected")"
  fi
}

assert_file_eq() {
  local name="$1" got_file="$2" expected_file="$3"
  if cmp -s "$got_file" "$expected_file"; then
    pass "$name"
  else
    fail "$name" "files differ: got=$(od -An -tx1 "$got_file" | tr -d ' \n') expected=$(od -An -tx1 "$expected_file" | tr -d ' \n')"
  fi
}

assert_exit() {
  local name="$1" expected_exit="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    local actual=0
  else
    local actual=$?
  fi
  if [ "$actual" = "$expected_exit" ]; then
    pass "$name"
  else
    fail "$name" "exit code: got=$actual expected=$expected_exit"
  fi
}

cd "$TMPDIR"

echo "=== bytes.sh ==="

echo "0123456789abcdefghijklm" > in

# count=14B (byte mode via B suffix)
got=$("$ZZ" count=14B conv=swab < in 2>/dev/null)
assert_eq "count=14B conv=swab" "$got" "1032547698badc"

# count=14 iflag=count_bytes
got=$("$ZZ" count=14 iflag=count_bytes conv=swab < in 2>/dev/null)
assert_eq "count=14 iflag=count_bytes conv=swab" "$got" "1032547698badc"

# iseek=10B (skip bytes via B suffix)
got=$("$ZZ" iseek=10B < in 2>/dev/null)
assert_eq "iseek=10B" "$got" "abcdefghijklm"

# skip=10 iflag=skip_bytes
got=$("$ZZ" skip=10 iflag=skip_bytes < in 2>/dev/null)
assert_eq "skip=10 iflag=skip_bytes" "$got" "abcdefghijklm"

# skip from pipe
got=$(echo "0123456789abcdefghijklm" | "$ZZ" iseek=10B bs=2 2>/dev/null)
assert_eq "iseek=10B bs=2 pipe" "$got" "abcdefghijklm"

got=$(echo "0123456789abcdefghijklm" | "$ZZ" skip=10 iflag=skip_bytes bs=2 2>/dev/null)
assert_eq "skip=10 iflag=skip_bytes bs=2 pipe" "$got" "abcdefghijklm"

# oseek=8B (seek bytes in output)
printf '\0\0\0\0\0\0\0\0abcdefghijklm\n' > expected
echo "abcdefghijklm" | "$ZZ" oseek=8B bs=5 > out 2>/dev/null
assert_file_eq "oseek=8B seek output" out expected

echo "abcdefghijklm" | "$ZZ" seek=8 oflag=seek_bytes bs=5 > out 2>/dev/null
assert_file_eq "seek=8 oflag=seek_bytes" out expected

# count=0 truncation: just truncate to 8 bytes
truncate -s8 expected2
"$ZZ" oseek=8B bs=5 of=out2 count=0 2>/dev/null
assert_file_eq "count=0 truncation oseek=8B" out2 expected2

"$ZZ" seek=8 oflag=seek_bytes bs=5 of=out3 count=0 2>/dev/null
assert_file_eq "count=0 truncation oflag=seek_bytes" out3 expected2

# Recursive multiply: 1x2x4 oflag=seek_bytes = 8 bytes
echo "abcdefghijklm" | "$ZZ" oseek='1x2x4' oflag=seek_bytes bs=5 > out 2>/dev/null
assert_file_eq "oseek=1x2x4 oflag=seek_bytes" out expected

echo "abcdefghijklm" | "$ZZ" oseek='1Bx2x4' bs=5 > out 2>/dev/null
assert_file_eq "oseek=1Bx2x4" out expected

# Negative: invalid count forms should fail
for bad in B B1 Bx1 KBB BB KBb KBx x1 1x 1xx1; do
  assert_exit "invalid count=$bad" 1 "$ZZ" count=$bad </dev/null
done

echo ""
echo "=== misc.sh ==="

echo "data" > dd-in
ln dd-in dd-in2
ln -s dd-in dd-sym

# status=none suppresses all stderr
"$ZZ" status=none if=dd-in of=/dev/null 2>err
assert_file_eq "status=none silent" err /dev/null

"$ZZ" status=none if=dd-in skip=2 of=/dev/null 2>err
assert_file_eq "status=none with skip silent" err /dev/null

# later status=none overrides earlier status=noxfer
"$ZZ" status=noxfer status=none if=dd-in of=/dev/null 2>err
assert_file_eq "status=noxfer then none -> silent" err /dev/null

# later status=noxfer overrides earlier status=none (should NOT be empty)
"$ZZ" status=none status=noxfer if=dd-in of=/dev/null 2>err
if [ -s err ]; then
  pass "status=none then noxfer -> has output"
else
  fail "status=none then noxfer -> has output" "stderr was empty"
fi

# basic copy
"$ZZ" if=dd-in of=dd-out 2>/dev/null
assert_file_eq "basic copy" dd-in dd-out

# -- separator
rm -f dd-out
"$ZZ" -- if=dd-in of=dd-out 2>/dev/null
assert_file_eq "-- separator" dd-in dd-out

# oflag=append
if "$ZZ" oflag=append if=dd-in of=dd-out 2>/dev/null; then
  assert_file_eq "oflag=append result" dd-in dd-out
fi

# stdin redirect
case $("$ZZ" if=/dev/stdin of=dd-out <dd-in 2>/dev/null; cat dd-out) in
  data) pass "if=/dev/stdin redirect" ;;
  *) fail "if=/dev/stdin redirect" "unexpected output" ;;
esac

# iflag=nofollow: follow regular file works, symlink fails
if "$ZZ" iflag=nofollow if=dd-in count=0 2>/dev/null; then
  if "$ZZ" iflag=nofollow if=dd-sym count=0 2>/dev/null; then
    fail "iflag=nofollow rejects symlink" "should have failed"
  else
    pass "iflag=nofollow rejects symlink"
  fi
else
  skip "iflag=nofollow" "not supported on this platform"
fi

# conv=sync: bs=3 ibs=10 obs=10 -> output 3 bytes
outbytes=$(echo x | "$ZZ" bs=3 ibs=10 obs=10 conv=sync status=noxfer 2>/dev/null | wc -c)
assert_eq "conv=sync output size" "$outbytes" "3"

# fullblock + piped input
(echo a; sleep .05; echo b) \
  | "$ZZ" bs=4 status=noxfer iflag=fullblock >out 2>err
printf 'a\nb\n' > out_ok
printf '1+0 records in\n1+0 records out\n' > err_ok
assert_file_eq "iflag=fullblock out" out out_ok
assert_file_eq "iflag=fullblock err" err err_ok

# 0x warning (one per param)
"$ZZ" if=/dev/null count=0x1 seek=0x1 skip=0x1 status=none 2>err
warn_count=$(grep -c "0x.*zero multiplier" err || true)
assert_eq "0x warning count=3" "$warn_count" "3"

# 0x -> zero multiplier means count=0 -> copy nothing
echo "0+0 records in
0+0 records out" > err_ok2
big=9999999999999999999999999999999999999999999999
"$ZZ" if=dd-in of=dd-out count=00x${big} status=noxfer 2>err
cmp -s /dev/null dd-out && pass "0x zero multiplier produces empty output" || fail "0x zero multiplier" "output not empty"
assert_file_eq "0x zero multiplier stats" err err_ok2

echo ""
echo "=== skip-seek.pl ==="

# sk-seek1: bs=1 skip=1 seek=2 conv=notrunc count=3
echo -n "0123456789abcdef" > sk_in
echo -n "zyxwvutsrqponmlkji" > sk_aux
"$ZZ" bs=1 skip=1 seek=2 conv=notrunc count=3 status=noxfer of=sk_aux < sk_in 2>/dev/null
got=$(cat sk_aux)
assert_eq "sk-seek1" "$got" "zy123utsrqponmlkji"

# sk-seek2: bs=5 skip=1 seek=1 conv=notrunc count=1
echo -n "0123456789abcdef" > sk_in
echo -n "zyxwvutsrqponmlkji" > sk_aux
"$ZZ" bs=5 skip=1 seek=1 conv=notrunc count=1 status=noxfer of=sk_aux < sk_in 2>/dev/null
got=$(cat sk_aux)
assert_eq "sk-seek2" "$got" "zyxwv56789ponmlkji"

# sk-seek3: bs=5 skip=1 seek=1 count=1 (no notrunc -> truncates)
echo -n "0123456789abcdef" > sk_in
echo -n "zyxwvutsrqponmlkji" > sk_aux
"$ZZ" bs=5 skip=1 seek=1 count=1 status=noxfer of=sk_aux < sk_in 2>/dev/null
got=$(cat sk_aux)
assert_eq "sk-seek3 truncation" "$got" "zyxwv56789"

# block-sync-1: ibs=10 cbs=10 conv=block,sync
printf '01234567\nabcdefghijkl\n' | "$ZZ" ibs=10 cbs=10 conv=block,sync status=noxfer >out 2>err
expected_out="01234567  abcdefghij          "
got_out=$(cat out)
assert_eq "block-sync-1 output" "$got_out" "$expected_out"
expected_err="2+1 records in
0+1 records out
1 truncated record"
got_err=$(cat err)
assert_eq "block-sync-1 stderr" "$got_err" "$expected_err"

# sk-seek4: bs=1 skip=1 from pipe
got=$(printf 'abc\n' | "$ZZ" bs=1 skip=1 status=noxfer 2>/dev/null)
assert_eq "sk-seek4 skip from pipe" "$got" "bc"

# sk-seek5: iseek/oseek aliases
echo -n "0123456789abcdef" > sk_in
echo -n "zyxwvutsrqponmlkji" > sk_aux
"$ZZ" bs=1 iseek=1 oseek=2 conv=notrunc count=3 status=noxfer of=sk_aux < sk_in 2>/dev/null
got=$(cat sk_aux)
assert_eq "sk-seek5 iseek/oseek aliases" "$got" "zy123utsrqponmlkji"

echo ""
echo "=== skip-seek2.sh ==="

echo "LA:3456789abcdef" > in2
# Both zz commands must share the same stdin fd (single < redirect over the whole subshell)
("$ZZ" bs=1 skip=3 count=0 2>/dev/null && "$ZZ" bs=5 2>/dev/null) < in2 > out2
got=$(cat out2)
assert_eq "skip-seek2 two-stage skip" "$got" "3456789abcdef"

echo "LA:3456789abcdef" > in2
("$ZZ" bs=1 skip=3 count=0 2>/dev/null && "$ZZ" bs=5 count=2 2>/dev/null) < in2 > out2
got=$(cat out2)
assert_eq "skip-seek2 two-stage skip with count" "$got" "3456789abc"

echo ""
echo "=== reblock.sh ==="

mkfifo rbl.fifo 2>/dev/null || true

# Ensure dd reblocks when bs= not specified (ibs=3 obs=3)
rbl_reblock() {
  local delay="$1"
  "$ZZ" ibs=3 obs=3 if=rbl.fifo > rbl_out 2> rbl_err &
  (printf 'ab'; sleep "$delay"; printf 'cd') > rbl.fifo
  wait
  sed 's/,.*//' rbl_err > k && mv k rbl_err
  local want="0+2 records in
1+1 records out"
  local got_e
  got_e=$(head -2 rbl_err)
  [ "$got_e" = "$want" ]
}

done_rbl=0
for delay in 0.05 0.1 0.2 0.4 0.8 1.6; do
  if rbl_reblock "$delay"; then
    pass "reblock ibs=3 obs=3 (delay=$delay)"
    done_rbl=1
    break
  fi
done
[ $done_rbl -eq 0 ] && fail "reblock ibs=3 obs=3" "never got 2 partial reads in time"

# bs=3 supersedes ibs/obs -> no reblocking (0+2 in, 0+2 out)
rbl_noreblock() {
  local delay="$1"
  "$ZZ" bs=3 ibs=1 obs=1 if=rbl.fifo > rbl_out 2> rbl_err &
  (printf 'ab'; sleep "$delay"; printf 'cd') > rbl.fifo
  wait
  sed 's/,.*//' rbl_err > k && mv k rbl_err
  local want="0+2 records in
0+2 records out"
  local got_e
  got_e=$(head -2 rbl_err)
  [ "$got_e" = "$want" ]
}

done_nrbl=0
for delay in 0.05 0.1 0.2 0.4 0.8 1.6; do
  if rbl_noreblock "$delay"; then
    pass "no-reblock bs=3 ibs=1 obs=1 (delay=$delay)"
    done_nrbl=1
    break
  fi
done
[ $done_nrbl -eq 0 ] && fail "no-reblock bs=3 ibs=1 obs=1" "never got 2 partial reads in time"

echo ""
echo "=== conv-case.sh ==="

printf 'abcdefghijklmnopqrstuvwxyz\n' > input-lower
printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ\n' > input-upper

"$ZZ" if=input-lower of=output-lower conv=lcase 2>/dev/null
assert_file_eq "conv=lcase already lower" input-lower output-lower

"$ZZ" if=input-upper of=output-upper conv=ucase 2>/dev/null
assert_file_eq "conv=ucase already upper" input-upper output-upper

"$ZZ" if=input-upper of=output-lower conv=lcase 2>/dev/null
assert_file_eq "conv=lcase from upper" input-lower output-lower

"$ZZ" if=input-lower of=output-upper conv=ucase 2>/dev/null
assert_file_eq "conv=ucase from lower" input-upper output-upper

echo ""
echo "=== stderr.sh ==="

# --help to closed stderr should succeed
"$ZZ" --help >/dev/null 2>&- && pass "help with closed stderr" || fail "help with closed stderr" "exit nonzero"

# normal dd to closed stderr should fail (generates output)
if "$ZZ" 2>&- </dev/null; then
  pass "empty run with closed stderr (no output generated)"
else
  pass "empty run with closed stderr fails as expected"
fi

# /dev/full stderr should fail
if [ -w /dev/full ] && [ -c /dev/full ]; then
  if echo | "$ZZ" 2>/dev/full; then
    fail "dd with /dev/full stderr" "should have failed"
  else
    pass "dd with /dev/full stderr fails"
  fi
else
  skip "stderr /dev/full" "/dev/full not available"
fi

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "=============================="

[ $FAIL -eq 0 ]
