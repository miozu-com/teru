//! Linux platform abstraction.
//!
//! Auto-detects Wayland vs X11 at runtime.  If WAYLAND_DISPLAY is set
//! and the Wayland backend initialises successfully, use it; otherwise
//! fall back to X11 (which is fully implemented).

const std = @import("std");
const x11 = @import("x11.zig");
const wayland = @import("wayland.zig");

// ── Shared event types ──────────────────────────────────────────

pub const KeyEvent = struct {
    keycode: u32,
    modifiers: u32,
};

pub const Event = union(enum) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    resize: struct { width: u32, height: u32 },
    close,
    focus_in,
    focus_out,
    expose,
    none,
};

// ── Platform union ──────────────────────────────────────────────

pub const Platform = union(enum) {
    x11: x11.X11Window,
    wayland_: wayland.WaylandWindow,

    pub fn init(width: u32, height: u32, title: []const u8) !Platform {
        // Try Wayland first if the environment advertises it.
        if (std.posix.getenv("WAYLAND_DISPLAY")) |_| {
            if (wayland.WaylandWindow.init(width, height, title)) |w| {
                return .{ .wayland_ = w };
            } else |_| {}
        }
        // Fall back to X11.
        return .{ .x11 = try x11.X11Window.init(width, height, title) };
    }

    pub fn deinit(self: *Platform) void {
        switch (self.*) {
            .x11 => |*w| w.deinit(),
            .wayland_ => |*w| w.deinit(),
        }
    }

    pub fn pollEvents(self: *Platform) ?Event {
        return switch (self.*) {
            .x11 => |*w| w.pollEvents(),
            .wayland_ => |*w| w.pollEvents(),
        };
    }

    pub fn swapBuffers(self: *Platform) void {
        switch (self.*) {
            .x11 => |*w| w.swapBuffers(),
            .wayland_ => |*w| w.swapBuffers(),
        }
    }

    pub fn getSize(self: *const Platform) struct { width: u32, height: u32 } {
        return switch (self.*) {
            .x11 => |*w| w.getSize(),
            .wayland_ => |*w| w.getSize(),
        };
    }

    pub fn getProcAddress(_: *const Platform, name: [*:0]const u8) ?*const anyopaque {
        return x11.X11Window.getProcAddress(name);
    }

    pub fn getProcAddressStatic(name: [*:0]const u8) ?*const anyopaque {
        return x11.X11Window.getProcAddress(name);
    }
};
