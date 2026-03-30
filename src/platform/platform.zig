//! Top-level platform abstraction.
//!
//! Selects the correct windowing backend at comptime based on the
//! target OS.  Linux: X11 (Wayland fallback planned), macOS: AppKit
//! via ObjC runtime, Windows: Win32 API.

const builtin = @import("builtin");

pub const Event = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Event,
    .macos => @import("macos/platform.zig").Event,
    .windows => @import("windows/platform.zig").Event,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const KeyEvent = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").KeyEvent,
    .macos => @import("macos/platform.zig").KeyEvent,
    .windows => @import("windows/platform.zig").KeyEvent,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const Size = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Size,
    .macos => @import("macos/platform.zig").Size,
    .windows => @import("windows/platform.zig").Size,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const Platform = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Platform,
    .macos => @import("macos/platform.zig").Platform,
    .windows => @import("windows/platform.zig").Platform,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};
