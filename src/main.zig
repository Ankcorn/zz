const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const posix = std.posix;

const ZzError = error{
    InvalidArgument,
    InvalidConv,
    InvalidFlag,
};

// Parse a size expression like "4k", "2x3" for general operands (bs=, ibs=, obs=, cbs=).
// B here means 512 bytes. Zero is rejected.
fn parseSize(s: []const u8) !u64 {
    if (s.len == 0) return ZzError.InvalidArgument;
    if (s[0] == 'x') return ZzError.InvalidArgument;
    if (s[s.len - 1] == 'x') return ZzError.InvalidArgument;
    if (mem.indexOf(u8, s, "xx") != null) return ZzError.InvalidArgument;
    if (s[0] == 'B') return ZzError.InvalidArgument;
    var result: u64 = 1;
    var it = mem.splitScalar(u8, s, 'x');
    while (it.next()) |part| {
        if (part.len == 0) return ZzError.InvalidArgument;
        const v = try parseUnit(part);
        if (v == 0) return ZzError.InvalidArgument; // FIX #2: zero block size is invalid
        result = std.math.mul(u64, result, v) catch return ZzError.InvalidArgument;
    }
    return result;
}

fn parseUnit(s: []const u8) !u64 {
    if (s.len == 0) return ZzError.InvalidArgument;
    if (s.len >= 2 and s[0] == '0' and s[1] == 'x') return 0;
    const last = s[s.len - 1];
    const mult: u64 = switch (last) {
        'c' => 1,
        'w' => 2,
        'b' => 512,
        'k', 'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        'T' => 1024 * 1024 * 1024 * 1024,
        'B' => 512,
        else => 0,
    };
    if (mult > 0) {
        const num_part = s[0 .. s.len - 1];
        if (num_part.len == 0) return ZzError.InvalidArgument;
        const num = std.fmt.parseInt(u64, num_part, 10) catch return ZzError.InvalidArgument;
        return std.math.mul(u64, num, mult) catch return ZzError.InvalidArgument;
    }
    return std.fmt.parseInt(u64, s, 10) catch return ZzError.InvalidArgument;
}

// Parse count/skip/seek params where 'B' anywhere in expression means:
//   - byte mode (not block mode)
//   - contributes factor 1 (not 512) to the product
// Examples: "8B"->bytes=true,val=8  "1Bx2x4"->bytes=true,val=8  "2Bx4B"->bytes=true,val=8
fn parseCountParam(s: []const u8) !struct { val: u64, bytes: bool } {
    if (s.len == 0) return ZzError.InvalidArgument;
    if (s[0] == 'x') return ZzError.InvalidArgument;
    if (s[s.len - 1] == 'x') return ZzError.InvalidArgument;
    if (mem.indexOf(u8, s, "xx") != null) return ZzError.InvalidArgument;
    if (s[0] == 'B') return ZzError.InvalidArgument;

    var bytes_mode = false;
    var result: u64 = 1;
    var it = mem.splitScalar(u8, s, 'x');
    while (it.next()) |part| {
        if (part.len == 0) return ZzError.InvalidArgument;
        if (part.len >= 2 and part[0] == '0' and part[1] == 'x') return .{ .val = 0, .bytes = bytes_mode };
        if (part.len > 1 and part[part.len - 1] == 'B') {
            bytes_mode = true;
            const num_str = part[0 .. part.len - 1];
            const num = std.fmt.parseInt(u64, num_str, 10) catch return ZzError.InvalidArgument;
            if (num == 0) return .{ .val = 0, .bytes = true };
            result = std.math.mul(u64, result, num) catch return ZzError.InvalidArgument;
        } else if (mem.eql(u8, part, "B")) {
            return ZzError.InvalidArgument;
        } else {
            const v = try parseCountUnit(part);
            if (v == 0) return .{ .val = 0, .bytes = bytes_mode };
            result = std.math.mul(u64, result, v) catch return ZzError.InvalidArgument;
        }
    }
    return .{ .val = result, .bytes = bytes_mode };
}

fn parseCountUnit(s: []const u8) !u64 {
    if (s.len == 0) return ZzError.InvalidArgument;
    if (s[0] == '0' and s.len >= 2 and s[1] == 'x') return 0;
    const last = s[s.len - 1];
    const mult: u64 = switch (last) {
        'c' => 1,
        'w' => 2,
        'b' => 512,
        'k', 'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        'T' => 1024 * 1024 * 1024 * 1024,
        else => 0,
    };
    if (mult > 0) {
        const num_part = s[0 .. s.len - 1];
        if (num_part.len == 0) return ZzError.InvalidArgument;
        const num = std.fmt.parseInt(u64, num_part, 10) catch return ZzError.InvalidArgument;
        return std.math.mul(u64, num, mult) catch return ZzError.InvalidArgument;
    }
    return std.fmt.parseInt(u64, s, 10) catch return ZzError.InvalidArgument;
}

const ConvFlags = struct {
    swab: bool = false,
    notrunc: bool = false,
    sync: bool = false,
    block: bool = false,
    unblock: bool = false,
    lcase: bool = false,
    ucase: bool = false,
    ascii: bool = false,
    ebcdic: bool = false,
    ibm: bool = false,
    excl: bool = false,
    nocreat: bool = false,
    sparse: bool = false,
    fdatasync: bool = false,
    fsync: bool = false,
};

const IFlags = struct {
    fullblock: bool = false,
    noatime: bool = false,
    nofollow: bool = false,
    directory: bool = false,
    nolinks: bool = false,
    count_bytes: bool = false,
    skip_bytes: bool = false,
};

const OFlags = struct {
    append: bool = false,
    noatime: bool = false,
    nolinks: bool = false,
    seek_bytes: bool = false,
    dsync: bool = false,
    sync: bool = false,
};

const StatusLevel = enum { default, none, noxfer, progress };

const Params = struct {
    if_path: ?[]const u8 = null,
    of_path: ?[]const u8 = null,
    bs: ?u64 = null,
    ibs: u64 = 512,
    obs: u64 = 512,
    cbs: u64 = 0,
    count: ?u64 = null,
    count_bytes: bool = false,
    skip: u64 = 0,
    skip_bytes: bool = false,
    seek: u64 = 0,
    seek_bytes: bool = false,
    conv: ConvFlags = .{},
    iflag: IFlags = .{},
    oflag: OFlags = .{},
    status: StatusLevel = .default,
};

fn has0x(s: []const u8) bool {
    if (s.len < 2) return false;
    if (s[0] == '0' and s[1] == 'x') return true;
    var it = mem.splitScalar(u8, s, 'x');
    _ = it.next();
    while (it.next()) |part| {
        if (part.len >= 2 and part[0] == '0' and part[1] == 'x') return true;
    }
    return false;
}

fn parseParams(allocator: std.mem.Allocator, args: []const []const u8, params: *Params, warnings: *std.ArrayList([]const u8)) !void {
    _ = allocator;
    for (args) |arg| {
        if (mem.eql(u8, arg, "--")) continue;

        if (mem.startsWith(u8, arg, "if=")) {
            params.if_path = arg[3..];
        } else if (mem.startsWith(u8, arg, "of=")) {
            params.of_path = arg[3..];
        } else if (mem.startsWith(u8, arg, "bs=")) {
            const s = arg[3..];
            if (has0x(s)) try warnings.append("bs");
            params.bs = try parseSize(s);
        } else if (mem.startsWith(u8, arg, "ibs=")) {
            params.ibs = try parseSize(arg[4..]);
        } else if (mem.startsWith(u8, arg, "obs=")) {
            params.obs = try parseSize(arg[4..]);
        } else if (mem.startsWith(u8, arg, "cbs=")) {
            params.cbs = try parseSize(arg[4..]);
        } else if (mem.startsWith(u8, arg, "count=")) {
            const s = arg[6..];
            if (has0x(s)) try warnings.append("count");
            const r = try parseCountParam(s);
            params.count = r.val;
            if (r.bytes) params.count_bytes = true;
        } else if (mem.startsWith(u8, arg, "skip=") or mem.startsWith(u8, arg, "iseek=")) {
            const offset: usize = if (mem.startsWith(u8, arg, "skip=")) 5 else 6;
            const s = arg[offset..];
            if (has0x(s)) try warnings.append("skip");
            const r = try parseCountParam(s);
            params.skip = r.val;
            if (r.bytes) params.skip_bytes = true;
        } else if (mem.startsWith(u8, arg, "seek=") or mem.startsWith(u8, arg, "oseek=")) {
            const offset: usize = if (mem.startsWith(u8, arg, "seek=")) 5 else 6;
            const s = arg[offset..];
            if (has0x(s)) try warnings.append("seek");
            const r = try parseCountParam(s);
            params.seek = r.val;
            if (r.bytes) params.seek_bytes = true;
        } else if (mem.startsWith(u8, arg, "conv=")) {
            try parseConv(arg[5..], &params.conv);
        } else if (mem.startsWith(u8, arg, "iflag=")) {
            try parseIFlag(arg[6..], &params.iflag, params);
        } else if (mem.startsWith(u8, arg, "oflag=")) {
            try parseOFlag(arg[6..], &params.oflag, params);
        } else if (mem.startsWith(u8, arg, "status=")) {
            const sv = arg[7..];
            if (mem.eql(u8, sv, "none")) {
                params.status = .none;
            } else if (mem.eql(u8, sv, "noxfer")) {
                params.status = .noxfer;
            } else if (mem.eql(u8, sv, "progress")) {
                params.status = .progress;
            } else {
                return ZzError.InvalidArgument;
            }
        } else {
            return ZzError.InvalidArgument;
        }
    }
}

fn parseConv(s: []const u8, conv: *ConvFlags) !void {
    var it = mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (mem.eql(u8, tok, "swab"))        conv.swab     = true
        else if (mem.eql(u8, tok, "notrunc")) conv.notrunc  = true
        else if (mem.eql(u8, tok, "sync"))    conv.sync     = true
        else if (mem.eql(u8, tok, "block"))   conv.block    = true
        else if (mem.eql(u8, tok, "unblock")) conv.unblock  = true
        else if (mem.eql(u8, tok, "lcase"))   conv.lcase    = true
        else if (mem.eql(u8, tok, "ucase"))   conv.ucase    = true
        else if (mem.eql(u8, tok, "ascii"))   conv.ascii    = true
        else if (mem.eql(u8, tok, "ebcdic"))  conv.ebcdic   = true
        else if (mem.eql(u8, tok, "ibm"))     conv.ibm      = true
        else if (mem.eql(u8, tok, "excl"))    conv.excl     = true
        else if (mem.eql(u8, tok, "nocreat")) conv.nocreat  = true
        else if (mem.eql(u8, tok, "sparse"))  conv.sparse   = true
        else if (mem.eql(u8, tok, "fdatasync")) conv.fdatasync = true
        else if (mem.eql(u8, tok, "fsync"))   conv.fsync    = true
        else return ZzError.InvalidConv;
    }
    // FIX #6: reject incompatible flag combinations
    if (conv.block and conv.unblock) return ZzError.InvalidConv;
    if (conv.lcase and conv.ucase)   return ZzError.InvalidConv;
    if (conv.ascii and conv.ebcdic)  return ZzError.InvalidConv;
    if (conv.ascii and conv.ibm)     return ZzError.InvalidConv;
    if (conv.ebcdic and conv.ibm)    return ZzError.InvalidConv;
}

fn parseIFlag(s: []const u8, iflag: *IFlags, params: *Params) !void {
    var it = mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (mem.eql(u8, tok, "fullblock"))    iflag.fullblock  = true
        else if (mem.eql(u8, tok, "noatime")) iflag.noatime    = true
        else if (mem.eql(u8, tok, "nofollow")) iflag.nofollow  = true
        else if (mem.eql(u8, tok, "directory")) iflag.directory = true
        else if (mem.eql(u8, tok, "nolinks")) iflag.nolinks    = true
        else if (mem.eql(u8, tok, "count_bytes")) { iflag.count_bytes = true; params.count_bytes = true; }
        else if (mem.eql(u8, tok, "skip_bytes"))  { iflag.skip_bytes  = true; params.skip_bytes  = true; }
        else return ZzError.InvalidFlag;
    }
}

fn parseOFlag(s: []const u8, oflag: *OFlags, params: *Params) !void {
    var it = mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (mem.eql(u8, tok, "append"))       oflag.append    = true
        else if (mem.eql(u8, tok, "noatime")) oflag.noatime   = true
        else if (mem.eql(u8, tok, "nolinks")) oflag.nolinks   = true
        else if (mem.eql(u8, tok, "seek_bytes")) { oflag.seek_bytes = true; params.seek_bytes = true; }
        else if (mem.eql(u8, tok, "dsync"))   oflag.dsync     = true
        else if (mem.eql(u8, tok, "sync"))    oflag.sync      = true
        else return ZzError.InvalidFlag;
    }
}

// EBCDIC -> ASCII (conv=ascii)
const ebcdic_to_ascii = [256]u8{
    0x00,0x01,0x02,0x03,0x9C,0x09,0x86,0x7F,0x97,0x8D,0x8E,0x0B,0x0C,0x0D,0x0E,0x0F,
    0x10,0x11,0x12,0x13,0x9D,0x85,0x08,0x87,0x18,0x19,0x92,0x8F,0x1C,0x1D,0x1E,0x1F,
    0x80,0x81,0x82,0x83,0x84,0x0A,0x17,0x1B,0x88,0x89,0x8A,0x8B,0x8C,0x05,0x06,0x07,
    0x90,0x91,0x16,0x93,0x94,0x95,0x96,0x04,0x98,0x99,0x9A,0x9B,0x14,0x15,0x9E,0x1A,
    0x20,0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xD5,0x2E,0x3C,0x28,0x2B,0x7C,
    0x26,0xA9,0xAA,0xAB,0xAC,0xAD,0xAE,0xAF,0xB0,0xB1,0x21,0x24,0x2A,0x29,0x3B,0x7E,
    0x2D,0x2F,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xCB,0x2C,0x25,0x5F,0x3E,0x3F,
    0xBA,0xBB,0xBC,0xBD,0xBE,0xBF,0xC0,0xC1,0xC2,0x60,0x3A,0x23,0x40,0x27,0x3D,0x22,
    0xC3,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,
    0xCA,0x6A,0x6B,0x6C,0x6D,0x6E,0x6F,0x70,0x71,0x72,0xCC,0xCD,0xCE,0xCF,0xD0,0xD1,
    0xD2,0xE5,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0xD3,0xD4,0xD6,0xD7,0xD8,0xD9,
    0xDA,0xDB,0xDC,0xDD,0xDE,0xDF,0xE0,0xE1,0xE2,0xE3,0xE4,0x5B,0xE6,0xE7,0xE8,0xE9,
    0x7B,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0xEA,0xEB,0xEC,0xED,0xEE,0xEF,
    0x7D,0x4A,0x4B,0x4C,0x4D,0x4E,0x4F,0x50,0x51,0x52,0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,
    0x5C,0x9F,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0xF6,0xF7,0xF8,0xF9,0xFA,0xFB,
    0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0xFC,0xFD,0xFE,0xFF,0x7C,0x9F,
};

// ASCII -> EBCDIC (conv=ebcdic)
const ascii_to_ebcdic = [256]u8{
    0x00,0x01,0x02,0x03,0x37,0x2D,0x2E,0x2F,0x16,0x05,0x25,0x0B,0x0C,0x0D,0x0E,0x0F,
    0x10,0x11,0x12,0x13,0x3C,0x3D,0x32,0x26,0x18,0x19,0x3F,0x27,0x1C,0x1D,0x1E,0x1F,
    0x40,0x5A,0x7F,0x7B,0x5B,0x6C,0x50,0x7D,0x4D,0x5D,0x5C,0x4E,0x6B,0x60,0x4B,0x61,
    0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0x7A,0x5E,0x4C,0x7E,0x6E,0x6F,
    0x7C,0xC1,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xD1,0xD2,0xD3,0xD4,0xD5,0xD6,
    0xD7,0xD8,0xD9,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xBA,0xE0,0xBB,0xB0,0x6D,
    0x79,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x91,0x92,0x93,0x94,0x95,0x96,
    0x97,0x98,0x99,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xC0,0x4F,0xD0,0xA1,0x07,
    0x20,0x21,0x22,0x23,0x24,0x15,0x06,0x17,0x28,0x29,0x2A,0x2B,0x2C,0x09,0x0A,0x1B,
    0x30,0x31,0x1A,0x33,0x34,0x35,0x36,0x08,0x38,0x39,0x3A,0x3B,0x04,0x14,0x3E,0xFF,
    0x41,0xAA,0x4A,0xB1,0x9F,0xB2,0x6A,0xB5,0xBD,0xB4,0x9A,0x8A,0x5F,0xCA,0xAF,0xBC,
    0x90,0x8F,0xEA,0xFA,0xBE,0xA0,0xB6,0xB3,0x9D,0xDA,0x9B,0x8B,0xB7,0xB8,0xB9,0xAB,
    0x64,0x65,0x62,0x66,0x63,0x67,0x9E,0x68,0x74,0x71,0x72,0x73,0x78,0x75,0x76,0x77,
    0xAC,0x69,0xED,0xEE,0xEB,0xEF,0xEC,0xBF,0x80,0xFD,0xFE,0xFB,0xFC,0xAD,0xAE,0x59,
    0x44,0x45,0x42,0x46,0x43,0x47,0x9C,0x48,0x54,0x51,0x52,0x53,0x58,0x55,0x56,0x57,
    0x8C,0x49,0xCD,0xCE,0xCB,0xCF,0xCC,0xE1,0x70,0xDD,0xDE,0xDB,0xDC,0x8D,0x8E,0xDF,
};

// ASCII -> EBCDIC IBM variant (conv=ibm) — FIX #5: ibm now actually converts
// Differences from standard EBCDIC: [ ] ^ ~ ` { } \ | differ in IBM variant.
const ascii_to_ebcdic_ibm = [256]u8{
    0x00,0x01,0x02,0x03,0x37,0x2D,0x2E,0x2F,0x16,0x05,0x25,0x0B,0x0C,0x0D,0x0E,0x0F,
    0x10,0x11,0x12,0x13,0x3C,0x3D,0x32,0x26,0x18,0x19,0x3F,0x27,0x1C,0x1D,0x1E,0x1F,
    0x40,0x5A,0x7F,0x7B,0x5B,0x6C,0x50,0x7D,0x4D,0x5D,0x5C,0x4E,0x6B,0x60,0x4B,0x61,
    0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0x7A,0x5E,0x4C,0x7E,0x6E,0x6F,
    0x7C,0xC1,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xD1,0xD2,0xD3,0xD4,0xD5,0xD6,
    0xD7,0xD8,0xD9,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xAD,0xE0,0xBD,0x5F,0x6D,
    0x79,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x91,0x92,0x93,0x94,0x95,0x96,
    0x97,0x98,0x99,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xC0,0x4F,0xD0,0xA1,0x07,
    0x20,0x21,0x22,0x23,0x24,0x15,0x06,0x17,0x28,0x29,0x2A,0x2B,0x2C,0x09,0x0A,0x1B,
    0x30,0x31,0x1A,0x33,0x34,0x35,0x36,0x08,0x38,0x39,0x3A,0x3B,0x04,0x14,0x3E,0xFF,
    0x41,0xAA,0x4A,0xB1,0x9F,0xB2,0x6A,0xB5,0xBD,0xB4,0x9A,0x8A,0x5F,0xCA,0xAF,0xBC,
    0x90,0x8F,0xEA,0xFA,0xBE,0xA0,0xB6,0xB3,0x9D,0xDA,0x9B,0x8B,0xB7,0xB8,0xB9,0xAB,
    0x64,0x65,0x62,0x66,0x63,0x67,0x9E,0x68,0x74,0x71,0x72,0x73,0x78,0x75,0x76,0x77,
    0xAC,0x69,0xED,0xEE,0xEB,0xEF,0xEC,0xBF,0x80,0xFD,0xFE,0xFB,0xFC,0xAD,0xAE,0x59,
    0x44,0x45,0x42,0x46,0x43,0x47,0x9C,0x48,0x54,0x51,0x52,0x53,0x58,0x55,0x56,0x57,
    0x8C,0x49,0xCD,0xCE,0xCB,0xCF,0xCC,0xE1,0x70,0xDD,0xDE,0xDB,0xDC,0x8D,0x8E,0xDF,
};

fn applyBytewiseConv(c: u8, conv: ConvFlags) u8 {
    var r = c;
    if (conv.lcase)  r = std.ascii.toLower(r);
    if (conv.ucase)  r = std.ascii.toUpper(r);
    if (conv.ascii)  r = ebcdic_to_ascii[r];
    if (conv.ebcdic) r = ascii_to_ebcdic[r];
    if (conv.ibm)    r = ascii_to_ebcdic_ibm[r]; // FIX #5
    return r;
}

const Stats = struct {
    in_full: u64 = 0,
    in_partial: u64 = 0,
    out_full: u64 = 0,
    out_partial: u64 = 0,
    bytes: u64 = 0,
    truncated: u64 = 0,
};

// Persistent state for conv=block across ibs reads
const BlockState = struct {
    col: usize = 0,
    truncating: bool = false,
    buf: []u8 = &[_]u8{},
    obs_pending: u64 = 0,
};

// Persistent state for conv=unblock across ibs reads
const UnblockState = struct {
    buf: []u8 = &[_]u8{},   // cbs-wide staging buffer
    filled: usize = 0,       // bytes currently in buf
    obs_pending: u64 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_raw);
    const args = args_raw[1..];

    const stderr_writer = io.getStdErr().writer();

    if (args.len == 1 and mem.eql(u8, args[0], "--help")) {
        const stdout = io.getStdOut().writer();
        try stdout.writeAll(
            \\Usage: zz [OPERAND]...
            \\Copy a file, converting and formatting according to the operands.
            \\
        );
        return;
    }
    if (args.len == 1 and mem.eql(u8, args[0], "--version")) {
        try io.getStdOut().writer().writeAll("zz 0.1.0\n");
        return;
    }

    var params = Params{};
    var warnings = std.ArrayList([]const u8).init(allocator);
    defer warnings.deinit();

    const args_const: []const []const u8 = @ptrCast(args);
    parseParams(allocator, args_const, &params, &warnings) catch |err| {
        try stderr_writer.print("zz: invalid argument: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    for (warnings.items) |_| {
        try stderr_writer.writeAll("zz: warning: '0x' is a zero multiplier; use '00x' if that is intended\n");
    }

    const ibs: u64 = if (params.bs) |b| b else params.ibs;
    const obs: u64 = if (params.bs) |b| b else params.obs;
    const reblock = (params.bs == null);

    // Open input
    var in_file: fs.File = undefined;
    var in_opened = false;
    if (params.if_path) |path| {
        var open_flags = posix.O{ .ACCMODE = .RDONLY };
        if (params.iflag.noatime)   open_flags.NOATIME   = true;
        if (params.iflag.nofollow)  open_flags.NOFOLLOW  = true;
        if (params.iflag.directory) open_flags.DIRECTORY = true;
        const fd = posix.open(path, open_flags, 0) catch |err| {
            try stderr_writer.print("zz: failed to open '{s}': {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        in_file = fs.File{ .handle = fd };
        in_opened = true;
    } else {
        in_file = io.getStdIn();
    }
    defer if (in_opened) in_file.close();

    if (params.iflag.nolinks) {
        const st = posix.fstat(in_file.handle) catch null;
        if (st) |s| {
            if (s.nlink > 1) {
                try stderr_writer.writeAll("zz: input: has too many links\n");
                std.process.exit(1);
            }
        }
    }

    // Open output
    var out_file: fs.File = undefined;
    var out_opened = false;
    if (params.of_path) |path| {
        // FIX #7: has_seek must check seek > 0, not just seek_bytes flag
        const has_seek = params.seek > 0;
        var open_flags = posix.O{ .ACCMODE = .WRONLY, .CREAT = true };
        if (!params.conv.notrunc and !has_seek) open_flags.TRUNC = true;
        if (params.conv.excl)    open_flags.EXCL   = true;
        if (params.conv.nocreat) open_flags.CREAT  = false;
        if (params.oflag.append) open_flags.APPEND = true;
        if (params.oflag.dsync)  open_flags.DSYNC  = true;
        if (params.oflag.sync)   open_flags.SYNC   = true;
        if (params.oflag.nolinks) {
            const st = posix.fstatat(posix.AT.FDCWD, path, 0) catch null;
            if (st) |s| {
                if (s.nlink > 1) {
                    try stderr_writer.print("zz: {s}: has too many links\n", .{path});
                    std.process.exit(1);
                }
            }
        }
        const fd = posix.open(path, open_flags, 0o666) catch |err| {
            try stderr_writer.print("zz: failed to open '{s}': {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        out_file = fs.File{ .handle = fd };
        out_opened = true;
    } else {
        out_file = io.getStdOut();
    }
    defer if (out_opened) out_file.close();

    // Skip input — FIX #1: use checked multiply to avoid overflow crash
    if (params.skip > 0) {
        const skip_bytes: u64 = if (params.skip_bytes)
            params.skip
        else
            std.math.mul(u64, params.skip, ibs) catch std.math.maxInt(i64);
        in_file.seekBy(@intCast(@min(skip_bytes, @as(u64, std.math.maxInt(i64))))) catch {
            // Non-seekable (pipe): read and discard
            var discard = try allocator.alloc(u8, 65536);
            defer allocator.free(discard);
            var remaining = skip_bytes;
            while (remaining > 0) {
                const n = in_file.read(discard[0..@min(remaining, discard.len)]) catch break;
                if (n == 0) break;
                remaining -= n;
            }
        };
    }

    // Seek output — FIX #1: use checked multiply to avoid overflow crash
    if (params.seek > 0 or (params.seek_bytes and params.seek == 0 and params.count != null and params.count.? == 0)) {
        const seek_bytes: u64 = if (params.seek_bytes)
            params.seek
        else
            std.math.mul(u64, params.seek, obs) catch std.math.maxInt(i64);
        // seekTo can handle large values for sparse files; fallback zero-fills for pipes
        out_file.seekTo(seek_bytes) catch |seek_err| {
            if (seek_err == error.Unseekable) {
                // Non-seekable output (pipe/stdout): write zeros to advance position
                var zeros = try allocator.alloc(u8, 65536);
                defer allocator.free(zeros);
                @memset(zeros, 0);
                var remaining = seek_bytes;
                while (remaining > 0) {
                    const n = @min(remaining, zeros.len);
                    try out_file.writeAll(zeros[0..n]);
                    remaining -= n;
                }
            }
            // Other errors (e.g. value too large): silently ignore, write at current pos
        };
    }

    var stats = Stats{};
    const count_is_zero = params.count != null and params.count.? == 0;

    if (!count_is_zero) {
        var ibuf = try allocator.alloc(u8, @intCast(ibs));
        defer allocator.free(ibuf);
        var obuf = try allocator.alloc(u8, @intCast(obs));
        defer allocator.free(obuf);
        var obuf_len: usize = 0;
        var bytes_transferred: u64 = 0;
        var blocks_copied: u64 = 0;

        var block_state = BlockState{};
        if (params.conv.block and params.cbs > 0) {
            block_state.buf = try allocator.alloc(u8, @intCast(params.cbs));
            @memset(block_state.buf, ' ');
        }
        defer if (block_state.buf.len > 0) allocator.free(block_state.buf);

        // FIX #3/#4: unblock state persists across reads, handles partial final record
        var unblock_state = UnblockState{};
        if (params.conv.unblock and params.cbs > 0) {
            unblock_state.buf = try allocator.alloc(u8, @intCast(params.cbs));
        }
        defer if (unblock_state.buf.len > 0) allocator.free(unblock_state.buf);

        main_loop: while (true) {
            if (params.count) |cnt| {
                if (params.count_bytes) {
                    if (bytes_transferred >= cnt) break;
                } else {
                    if (blocks_copied >= cnt) break;
                }
            }

            const want: usize = blk: {
                var w: u64 = ibs;
                if (params.count_bytes and params.count != null) {
                    w = @min(w, params.count.? - bytes_transferred);
                }
                break :blk @intCast(w);
            };

            var nread: usize = 0;
            if (params.iflag.fullblock) {
                while (nread < want) {
                    const n = in_file.read(ibuf[nread..want]) catch break;
                    if (n == 0) break;
                    nread += n;
                }
            } else {
                nread = in_file.read(ibuf[0..want]) catch 0;
            }
            if (nread == 0) break;

            if (nread == ibs) stats.in_full += 1 else stats.in_partial += 1;
            bytes_transferred += nread;
            blocks_copied += 1;

            for (ibuf[0..nread]) |*c| c.* = applyBytewiseConv(c.*, params.conv);
            if (params.conv.swab) {
                var i: usize = 0;
                while (i + 1 < nread) : (i += 2) {
                    const tmp = ibuf[i]; ibuf[i] = ibuf[i + 1]; ibuf[i + 1] = tmp;
                }
            }

            var block_data: []u8 = ibuf[0..nread];
            var sync_buf: ?[]u8 = null;
            defer if (sync_buf) |sb| allocator.free(sb);

            if (params.conv.sync and nread < ibs) {
                sync_buf = try allocator.alloc(u8, @intCast(ibs));
                @memcpy(sync_buf.?[0..nread], ibuf[0..nread]);
                const pad: u8 = if (params.conv.block or params.conv.unblock) ' ' else 0;
                @memset(sync_buf.?[nread..], pad);
                block_data = sync_buf.?[0..@intCast(ibs)];
            }

            // conv=block: stateful across reads
            if (params.conv.block and params.cbs > 0) {
                for (block_data) |c| {
                    if (c == '\n') {
                        if (block_state.truncating) {
                            stats.truncated += 1;
                        } else {
                            try writeObsChunk(out_file, block_state.buf, obs, &stats, &block_state);
                        }
                        @memset(block_state.buf, ' ');
                        block_state.col = 0;
                        block_state.truncating = false;
                    } else if (block_state.truncating) {
                        // discard until \n
                    } else if (block_state.col < params.cbs) {
                        block_state.buf[block_state.col] = c;
                        block_state.col += 1;
                        if (block_state.col == params.cbs) {
                            try writeObsChunk(out_file, block_state.buf, obs, &stats, &block_state);
                            @memset(block_state.buf, ' ');
                            block_state.col = 0;
                            block_state.truncating = true;
                        }
                    }
                }
                continue :main_loop;
            }

            // conv=unblock: stateful across reads — FIX #3/#4
            if (params.conv.unblock and params.cbs > 0) {
                for (block_data) |c| {
                    unblock_state.buf[unblock_state.filled] = c;
                    unblock_state.filled += 1;
                    if (unblock_state.filled == params.cbs) {
                        // Trim trailing spaces and emit with newline
                        var end = unblock_state.filled;
                        while (end > 0 and unblock_state.buf[end - 1] == ' ') end -= 1;
                        try writeObsUnblock(out_file, unblock_state.buf[0..end], obs, &stats, &unblock_state);
                        const nl = [1]u8{'\n'};
                        try out_file.writeAll(&nl);
                        stats.bytes += 1;
                        unblock_state.filled = 0;
                    }
                }
                continue :main_loop;
            }

            // Normal write path
            if (!reblock) {
                var pos: usize = 0;
                while (pos < block_data.len) {
                    const end = @min(pos + @as(usize, @intCast(obs)), block_data.len);
                    const chunk = block_data[pos..end];
                    out_file.writeAll(chunk) catch |err| {
                        try stderr_writer.print("zz: write error: {s}\n", .{@errorName(err)});
                        std.process.exit(1);
                    };
                    if (chunk.len == obs) stats.out_full += 1 else stats.out_partial += 1;
                    stats.bytes += chunk.len;
                    pos = end;
                }
            } else {
                var src_pos: usize = 0;
                while (src_pos < block_data.len) {
                    const space = @as(usize, @intCast(obs)) - obuf_len;
                    const to_copy = @min(space, block_data.len - src_pos);
                    @memcpy(obuf[obuf_len .. obuf_len + to_copy], block_data[src_pos .. src_pos + to_copy]);
                    obuf_len += to_copy;
                    src_pos += to_copy;
                    if (obuf_len == @as(usize, @intCast(obs))) {
                        out_file.writeAll(obuf[0..obuf_len]) catch |err| {
                            try stderr_writer.print("zz: write error: {s}\n", .{@errorName(err)});
                            std.process.exit(1);
                        };
                        stats.out_full += 1;
                        stats.bytes += obuf_len;
                        obuf_len = 0;
                    }
                }
            }
        } // end main_loop

        // Flush pending conv=block partial record
        if (params.conv.block and params.cbs > 0 and block_state.col > 0 and !block_state.truncating) {
            try writeObsChunk(out_file, block_state.buf, obs, &stats, &block_state);
        }
        if (params.conv.block and params.cbs > 0) {
            flushObsPending(obs, &stats, &block_state.obs_pending);
        }

        // FIX #3: flush pending conv=unblock partial record (no full cbs block at EOF)
        if (params.conv.unblock and params.cbs > 0 and unblock_state.filled > 0) {
            var end = unblock_state.filled;
            while (end > 0 and unblock_state.buf[end - 1] == ' ') end -= 1;
            try writeObsUnblock(out_file, unblock_state.buf[0..end], obs, &stats, &unblock_state);
            const nl = [1]u8{'\n'};
            try out_file.writeAll(&nl);
            stats.bytes += 1;
        }
        if (params.conv.unblock and params.cbs > 0) {
            flushObsPending(obs, &stats, &unblock_state.obs_pending);
        }

        // Flush reblock buffer
        if (reblock and obuf_len > 0) {
            out_file.writeAll(obuf[0..obuf_len]) catch |err| {
                try stderr_writer.print("zz: write error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            stats.out_partial += 1;
            stats.bytes += obuf_len;
        }
    }

    // Truncate output to write position after seek (matches coreutils behaviour)
    if (!params.conv.notrunc and params.seek > 0 and out_opened) {
        const pos = out_file.getPos() catch 0;
        out_file.setEndPos(pos) catch {};
    }

    // count=0 with seek: truncate to seek position
    if (count_is_zero and out_opened) {
        const seek_bytes: u64 = if (params.seek_bytes)
            params.seek
        else
            std.math.mul(u64, params.seek, obs) catch std.math.maxInt(i64);
        out_file.setEndPos(seek_bytes) catch {};
    }

    if (params.conv.fsync or params.conv.fdatasync) {
        out_file.sync() catch {};
    }

    if (params.status != .none) {
        try stderr_writer.print("{d}+{d} records in\n",  .{ stats.in_full,  stats.in_partial  });
        try stderr_writer.print("{d}+{d} records out\n", .{ stats.out_full, stats.out_partial });
        if (stats.truncated > 0) {
            try stderr_writer.print("{d} truncated record{s}\n", .{
                stats.truncated, if (stats.truncated == 1) "" else "s",
            });
        }
        if (params.status != .noxfer) {
            try stderr_writer.print("{d} bytes copied\n", .{stats.bytes});
        }
    }
}

// Write a cbs-wide block record, tracking full/partial at obs granularity
fn writeObsChunk(file: fs.File, data: []const u8, obs: u64, stats: *Stats, bs: *BlockState) !void {
    try file.writeAll(data);
    stats.bytes += data.len;
    bs.obs_pending += data.len;
    while (bs.obs_pending >= obs) {
        stats.out_full += 1;
        bs.obs_pending -= obs;
    }
}

// Same but for unblock state
fn writeObsUnblock(file: fs.File, data: []const u8, obs: u64, stats: *Stats, us: *UnblockState) !void {
    try file.writeAll(data);
    stats.bytes += data.len;
    us.obs_pending += data.len;
    while (us.obs_pending >= obs) {
        stats.out_full += 1;
        us.obs_pending -= obs;
    }
}

fn flushObsPending(obs: u64, stats: *Stats, pending: *u64) void {
    if (pending.* > 0) {
        stats.out_partial += 1;
        pending.* = 0;
    }
    _ = obs;
}

fn writeChunk(file: fs.File, data: []const u8, stats: *Stats) !void {
    try file.writeAll(data);
    stats.out_partial += 1;
    stats.bytes += data.len;
}
