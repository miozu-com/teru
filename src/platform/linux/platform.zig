//! Linux platform abstraction.
//!
//! Auto-detects Wayland vs X11 at runtime. CPU SIMD renderer blits
//! framebuffer to the window via xcb_put_image. No EGL or OpenGL.

const std = @import("std");
const x11 = @import("x11.zig");
const wayland = @import("wayland.zig");

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

pub const Size = struct { width: u32, height: u32 };

pub const Platform = union(enum) {
    x11: x11.X11Window,
    wayland_: wayland.WaylandWindow,

    pub fn init(width: u32, height: u32, title: []const u8) !Platform {
        if (std.posix.getenv("WAYLAND_DISPLAY")) |_| {
            if (wayland.WaylandWindow.init(width, height, title)) |w| {
                return .{ .wayland_ = w };
            } else |_| {}
        }
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

    pub fn putFramebuffer(self: *Platform, pixels: []const u32, width: u32, height: u32) void {
        switch (self.*) {
            .x11 => |*w| w.putFramebuffer(pixels, width, height),
            .wayland_ => {}, // TODO: wl_shm buffer
        }
    }

    pub fn getSize(self: *const Platform) Size {
        return switch (self.*) {
            .x11 => |*w| .{ .width = w.width, .height = w.height },
            .wayland_ => |*w| .{ .width = w.width, .height = w.height },
        };
    }
};
