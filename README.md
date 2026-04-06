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
