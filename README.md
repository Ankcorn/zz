> ⚠️ **WARNING: This is slop.** `zz` is a vibe-coded fork of `dd` written in Zig by Claude. It may eat your data, corrupt your filesystem, or summon demons. Use at your own risk. Do not use in production. Do not use near open flames.

---

# zz

A rewrite of `dd` in Zig, with tests ported from the [coreutils](https://github.com/coreutils/coreutils) `dd` test suite.

## Build

```sh
zig build
```

Binary lands at `zig-out/bin/zz`.

## Usage

Same operand syntax as `dd`:

```sh
zz if=input.bin of=output.bin bs=4096
echo "hello" | zz conv=ucase
zz if=/dev/urandom of=file.bin count=100 bs=1M
```

Supported operands: `if=`, `of=`, `bs=`, `ibs=`, `obs=`, `cbs=`, `count=`, `skip=`/`iseek=`, `seek=`/`oseek=`, `conv=`, `iflag=`, `oflag=`, `status=`

## Tests

```sh
bash run_tests.sh
```

Ported from the coreutils dd test suite: `bytes.sh`, `misc.sh`, `skip-seek.pl`, `skip-seek2.sh`, `reblock.sh`, `conv-case.sh`, `stderr.sh`.

```
Results: 55 passed, 0 failed, 0 skipped
```

## Real hardware results

Tested on a Raspberry Pi against a 58GB microSD card (`/dev/mmcblk0`).

| Test | Result |
|---|---|
| MBR read (512 bytes, raw device) | ✅ Valid `55 aa` signature |
| 1MB raw read vs dd | ✅ Byte-identical |
| 100MB sequential read | ✅ Matches dd throughput (~87 MB/s) |
| `/etc/passwd` file copy | ✅ Identical |
| Binary (`/usr/bin/ls`) copy | ✅ Identical |
| Partial read (`skip=2 count=4 bs=64`) | ✅ Identical output and stats |
| 10MB partition image vs dd | ✅ Same SHA256 |
| Round-trip copy at `bs=4096` | ✅ 2560+0 records, identical |
