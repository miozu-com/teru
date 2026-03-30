//! Top-level platform abstraction.
//!
//! Selects the correct windowing backend at comptime based on the
//! target OS.  Linux: X11 (Wayland fallback planned), macOS: AppKit
//! via ObjC runtime, Windows: Win32 API.

const builtin = @import("builtin");

pub const Event = @import("types.zig").Event;
pub const KeyEvent = @import("types.zig").KeyEvent;
pub const Size = @import("types.zig").Size;

pub const Platform = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Platform,
    .macos => @import("macos/platform.zig").Platform,
    .windows => @import("windows/platform.zig").Platform,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};
