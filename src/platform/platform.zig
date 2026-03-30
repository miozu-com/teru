//! Top-level platform abstraction.
//!
//! Selects the correct windowing backend at comptime based on the
//! target OS.  On Linux this gives you X11 (with Wayland fallback
//! once xdg-shell codegen is wired up).

const builtin = @import("builtin");

pub const Event = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Event,
    // .macos => @import("macos/platform.zig").Event,
    // .windows => @import("windows/platform.zig").Event,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const KeyEvent = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").KeyEvent,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};

pub const Platform = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig").Platform,
    else => @compileError("unsupported platform: " ++ @tagName(builtin.os.tag)),
};
