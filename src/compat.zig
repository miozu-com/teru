//! Compatibility layer for Zig 0.16-dev.
//!
//! Replaces removed APIs:
//!   - std.fs.cwd().openFile/createFile/deleteFile → raw POSIX fd ops
//!   - std.io.fixedBufferStream → MemStream (in-memory writer/reader)
//!   - std.time.nanoTimestamp() → clock_gettime(REALTIME)
//!   - std.Thread.sleep(ns) → linux.nanosleep

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// Minimal stat struct matching Linux x86_64 struct stat (for fstat)
const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    __pad0: u32 = 0,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: linux.timespec,
    mtim: linux.timespec,
    ctim: linux.timespec,
    __unused: [3]i64 = .{ 0, 0, 0 },
};

// libc fstat — std.c.fstat is void on Linux in 0.16-dev
extern "c" fn fstat(fd: posix.fd_t, buf: *Stat) c_int;

// ── File operations (replaces removed std.fs.cwd()) ─────────────

pub const File = struct {
    fd: posix.fd_t,

    pub fn close(self: File) void {
        _ = posix.system.close(self.fd);
    }

    /// Read entire file contents into an allocator-owned buffer (up to max_bytes).
    pub fn readToEndAlloc(self: File, allocator: Allocator, max_bytes: usize) ![]u8 {
        // Get file size via fstat
        var stat_buf: Stat = undefined;
        const stat_rc = fstat(self.fd, &stat_buf);
        if (stat_rc != 0) return error.StatFailed;
        const size: usize = @intCast(stat_buf.size);
        if (size > max_bytes) return error.FileTooBig;

        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        var total: usize = 0;
        while (total < size) {
            const n = posix.read(self.fd, buf[total..]) catch |err| switch (err) {
                else => return error.ReadFailed,
            };
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }

    /// Read all bytes into a pre-allocated buffer. Returns number of bytes read.
    pub fn readAll(self: File, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(self.fd, buf[total..]) catch |err| switch (err) {
                else => return error.ReadFailed,
            };
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn writeAll(self: File, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            const rc = std.c.write(self.fd, data[total..].ptr, data.len - total);
            if (rc < 0) return error.WriteFailed;
            if (rc == 0) return error.WriteFailed;
            total += @intCast(rc);
        }
    }

    /// Get file size.
    pub fn stat(self: File) !struct { size: usize } {
        var stat_buf: Stat = undefined;
        const stat_rc = fstat(self.fd, &stat_buf);
        if (stat_rc != 0) return error.StatFailed;
        return .{ .size = @intCast(stat_buf.size) };
    }
};

/// Open a file relative to CWD. Replaces std.fs.cwd().openFile().
pub fn openFile(path: []const u8, comptime _: struct {}) !File {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    return .{ .fd = fd };
}

/// Create a file relative to CWD. Replaces std.fs.cwd().createFile().
pub fn createFile(path: []const u8, comptime _: struct {}) !File {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    return .{ .fd = fd };
}

/// Check if a file is accessible (exists and readable).
pub fn access(path: []const u8) bool {
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = posix.system.close(fd);
    return true;
}

/// Delete a file. Replaces std.fs.cwd().deleteFile().
pub fn deleteFile(path_z: [*:0]const u8) void {
    _ = std.c.unlink(path_z);
}

// ── In-memory stream (replaces removed std.io.fixedBufferStream) ──

/// Minimal in-memory writer that provides writeAll/writeInt/writeByte.
pub const MemWriter = struct {
    buffer: []u8,
    pos: usize = 0,

    pub fn writeAll(self: *MemWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn writeByte(self: *MemWriter, byte: u8) !void {
        if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    pub fn writeInt(self: *MemWriter, comptime T: type, value: T, comptime endian: std.builtin.Endian) !void {
        const bytes = std.mem.toBytes(if (endian == .big) std.mem.nativeToBig(T, value) else std.mem.nativeToLittle(T, value));
        try self.writeAll(&bytes);
    }

    pub fn getWritten(self: *const MemWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};

/// Minimal in-memory reader that provides readAll/readInt/readByte.
pub const MemReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn readAll(self: *MemReader, dest: []u8) !usize {
        const avail = self.buffer.len - self.pos;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], self.buffer[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn readByte(self: *MemReader) !u8 {
        if (self.pos >= self.buffer.len) return error.EndOfStream;
        const byte = self.buffer[self.pos];
        self.pos += 1;
        return byte;
    }

    pub fn readInt(self: *MemReader, comptime T: type, comptime endian: std.builtin.Endian) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.buffer.len) return error.EndOfStream;
        const bytes = self.buffer[self.pos..][0..size];
        self.pos += size;
        const raw = std.mem.bytesToValue(T, bytes);
        return if (endian == .big) std.mem.bigToNative(T, raw) else std.mem.littleToNative(T, raw);
    }
};

/// Minimal dynamic writer backed by an allocator (replaces ArrayListAligned + writer).
pub const DynWriter = struct {
    items: []u8 = &.{},
    len: usize = 0,
    allocator: Allocator,

    pub fn writeAll(self: *DynWriter, data: []const u8) !void {
        try self.ensureCapacity(self.len + data.len);
        @memcpy(self.items[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn writeByte(self: *DynWriter, byte: u8) !void {
        try self.ensureCapacity(self.len + 1);
        self.items[self.len] = byte;
        self.len += 1;
    }

    pub fn writeInt(self: *DynWriter, comptime T: type, value: T, comptime endian: std.builtin.Endian) !void {
        const bytes = std.mem.toBytes(if (endian == .big) std.mem.nativeToBig(T, value) else std.mem.nativeToLittle(T, value));
        try self.writeAll(&bytes);
    }

    pub fn getWritten(self: *const DynWriter) []const u8 {
        return self.items[0..self.len];
    }

    pub fn deinit(self: *DynWriter) void {
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = .{ .allocator = self.allocator };
    }

    fn ensureCapacity(self: *DynWriter, needed: usize) !void {
        if (needed <= self.items.len) return;
        var new_cap = if (self.items.len == 0) @as(usize, 256) else self.items.len;
        while (new_cap < needed) new_cap *= 2;
        const new_buf = try self.allocator.alloc(u8, new_cap);
        if (self.len > 0) @memcpy(new_buf[0..self.len], self.items[0..self.len]);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = new_buf;
    }
};

// ── Time (replaces removed std.time.nanoTimestamp) ───────────────

pub fn nanoTimestamp() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ── Sleep (replaces removed std.Thread.sleep) ────────────────────

pub fn sleepNanos(ns: u64) void {
    const req = linux.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.nanosleep(&req, null);
}
