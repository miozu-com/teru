//! Wayland backend (stub — v0.0.1).
//!
//! Wayland's xdg-shell protocol requires generated protocol headers
//! produced by wayland-scanner.  Until that codegen is wired into the
//! build system, this file returns a clear error so the platform layer
//! falls back to X11.
//!
//! TODO (v0.0.2):
//!   1. Add `wayland-scanner` codegen step in build.zig
//!   2. Generate xdg-shell-client-protocol.h
//!   3. Implement WaylandWindow (wl_display + xdg_toplevel + EGL)

const platform = @import("platform.zig");

pub const Event = platform.Event;

pub const WaylandWindow = struct {
    width: u32,
    height: u32,
    is_open: bool,

    pub fn init(width: u32, height: u32, title: []const u8) !WaylandWindow {
        _ = width;
        _ = height;
        _ = title;
        return error.WaylandNotYetImplemented;
    }

    pub fn deinit(self: *WaylandWindow) void {
        _ = self;
    }

    pub fn pollEvents(self: *WaylandWindow) ?Event {
        _ = self;
        return null;
    }

    pub fn swapBuffers(self: *WaylandWindow) void {
        _ = self;
    }

    pub fn getSize(self: *const WaylandWindow) struct { width: u32, height: u32 } {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
        _ = name;
        return null;
    }
};
