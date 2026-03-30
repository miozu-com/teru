//! Wayland backend using xdg-shell + wl_shm.
//!
//! Creates a toplevel window via xdg_wm_base, blits CPU framebuffer
//! via shared-memory buffers (wl_shm). Keyboard events delivered as
//! raw keycodes (xkbcommon integration planned for later).
//!
//! Dependencies: libwayland-client, vendored xdg-shell protocol code.

const std = @import("std");
const platform = @import("platform.zig");

pub const Event = platform.Event;
pub const KeyEvent = platform.KeyEvent;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
});

// Linux syscall constants not exposed by std.posix
const MFD_CLOEXEC: c_uint = 0x0001;

/// Shared state for Wayland listener callbacks. Callbacks receive a
/// pointer to this struct via the `data` parameter.
const WaylandState = struct {
    compositor: ?*c.wl_compositor = null,
    xdg_wm_base: ?*c.struct_xdg_wm_base = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,

    // Pending dimensions from xdg_toplevel.configure (0 = use default)
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    configured: bool = false,
    close_requested: bool = false,

    // Keyboard state: ring buffer of events
    key_events: [32]Event = undefined,
    key_head: u32 = 0,
    key_tail: u32 = 0,
    has_focus: bool = false,

    // Modifier state from wl_keyboard.modifiers
    mods_depressed: u32 = 0,

    fn pushEvent(self: *WaylandState, ev: Event) void {
        const next = (self.key_head + 1) % 32;
        if (next == self.key_tail) return; // Full, drop oldest
        self.key_events[self.key_head] = ev;
        self.key_head = next;
    }

    fn popEvent(self: *WaylandState) ?Event {
        if (self.key_head == self.key_tail) return null;
        const ev = self.key_events[self.key_tail];
        self.key_tail = (self.key_tail + 1) % 32;
        return ev;
    }
};

pub const WaylandWindow = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    surface: *c.wl_surface,
    xdg_surface: *c.struct_xdg_surface,
    xdg_toplevel: *c.struct_xdg_toplevel,
    width: u32,
    height: u32,
    is_open: bool,

    // SHM buffer for framebuffer blitting
    buffer: ?*c.wl_buffer = null,
    shm_fd: std.posix.fd_t = -1,
    shm_data: ?[*]align(4096) u8 = null,
    shm_size: usize = 0,
    buf_width: u32 = 0,
    buf_height: u32 = 0,

    state: WaylandState,

    pub fn init(width: u32, height: u32, title: []const u8) !WaylandWindow {
        // 1. Connect to the Wayland display
        const display: *c.wl_display = c.wl_display_connect(null) orelse
            return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);

        // 2. Get registry
        const registry: *c.wl_registry = c.wl_display_get_registry(display) orelse
            return error.WaylandRegistryFailed;

        // Shared state for callbacks
        var state = WaylandState{};

        // 3. Listen for global objects
        if (c.wl_registry_add_listener(registry, &registry_listener, &state) < 0)
            return error.WaylandListenerFailed;

        // Roundtrip to receive globals
        if (c.wl_display_roundtrip(display) < 0)
            return error.WaylandRoundtripFailed;

        // Verify we got the required globals
        const compositor = state.compositor orelse return error.WaylandNoCompositor;
        const xdg_wm = state.xdg_wm_base orelse return error.WaylandNoXdgWmBase;
        const shm = state.shm orelse return error.WaylandNoShm;
        _ = shm;

        // 4. Set up xdg_wm_base ping listener
        if (c.xdg_wm_base_add_listener(xdg_wm, &xdg_wm_base_listener, &state) < 0)
            return error.WaylandListenerFailed;

        // 5. Set up seat/keyboard if available
        if (state.seat) |seat| {
            if (c.wl_seat_add_listener(seat, &seat_listener, &state) < 0)
                return error.WaylandListenerFailed;
        }

        // Another roundtrip to get seat capabilities
        if (c.wl_display_roundtrip(display) < 0)
            return error.WaylandRoundtripFailed;

        // 6. Create surface
        const surface: *c.wl_surface = c.wl_compositor_create_surface(compositor) orelse
            return error.WaylandSurfaceCreateFailed;
        errdefer c.wl_surface_destroy(surface);

        // 7. Create xdg_surface
        const xdg_surface: *c.struct_xdg_surface = c.xdg_wm_base_get_xdg_surface(xdg_wm, surface) orelse
            return error.WaylandXdgSurfaceFailed;
        errdefer c.xdg_surface_destroy(xdg_surface);

        if (c.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &state) < 0)
            return error.WaylandListenerFailed;

        // 8. Create xdg_toplevel
        const xdg_toplevel: *c.struct_xdg_toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse
            return error.WaylandToplevelFailed;
        errdefer c.xdg_toplevel_destroy(xdg_toplevel);

        if (c.xdg_toplevel_add_listener(xdg_toplevel, &xdg_toplevel_listener, &state) < 0)
            return error.WaylandListenerFailed;

        // 9. Set title — need a null-terminated copy
        var title_buf: [256]u8 = undefined;
        const title_len = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..title_len], title[0..title_len]);
        title_buf[title_len] = 0;
        c.xdg_toplevel_set_title(xdg_toplevel, @ptrCast(&title_buf));
        c.xdg_toplevel_set_app_id(xdg_toplevel, "teru");

        // 10. Initial commit (empty, triggers the compositor to send configure)
        c.wl_surface_commit(surface);

        // 11. Wait for the initial configure event
        while (!state.configured) {
            if (c.wl_display_dispatch(display) < 0)
                return error.WaylandDispatchFailed;
        }

        // Use compositor-requested size, or fallback to requested size
        const final_w = if (state.pending_width > 0) state.pending_width else width;
        const final_h = if (state.pending_height > 0) state.pending_height else height;

        var self = WaylandWindow{
            .display = display,
            .registry = registry,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .xdg_toplevel = xdg_toplevel,
            .width = final_w,
            .height = final_h,
            .is_open = true,
            .state = state,
        };

        // 12. Create initial SHM buffer
        self.createShmBuffer(final_w, final_h) catch {
            // Non-fatal — putFramebuffer will just be a no-op until resize succeeds
        };

        return self;
    }

    pub fn deinit(self: *WaylandWindow) void {
        self.destroyShmBuffer();

        if (self.state.keyboard) |kb| {
            c.wl_keyboard_destroy(kb);
        }
        if (self.state.seat) |seat| {
            c.wl_seat_destroy(seat);
        }

        c.xdg_toplevel_destroy(self.xdg_toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        c.wl_surface_destroy(self.surface);

        if (self.state.xdg_wm_base) |wm| {
            c.xdg_wm_base_destroy(wm);
        }
        if (self.state.compositor) |comp| {
            c.wl_compositor_destroy(comp);
        }
        if (self.state.shm) |shm| {
            c.wl_shm_destroy(shm);
        }

        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.is_open = false;
    }

    pub fn pollEvents(self: *WaylandWindow) ?Event {
        // Dispatch pending Wayland events (non-blocking)
        _ = c.wl_display_dispatch_pending(self.display);

        // Flush outgoing requests and prepare readable events
        if (c.wl_display_prepare_read(self.display) == 0) {
            // Check if there's data without blocking
            var fds = [1]std.posix.pollfd{.{
                .fd = c.wl_display_get_fd(self.display),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = c.wl_display_flush(self.display);
            const poll_result = std.posix.poll(&fds, 0) catch 0;
            if (poll_result > 0) {
                _ = c.wl_display_read_events(self.display);
                _ = c.wl_display_dispatch_pending(self.display);
            } else {
                c.wl_display_cancel_read(self.display);
            }
        }

        // Check for close request
        if (self.state.close_requested) {
            self.is_open = false;
            self.state.close_requested = false;
            return .close;
        }

        // Check for pending configure (resize)
        if (self.state.configured) {
            self.state.configured = false;
            const new_w = if (self.state.pending_width > 0) self.state.pending_width else self.width;
            const new_h = if (self.state.pending_height > 0) self.state.pending_height else self.height;
            if (new_w != self.width or new_h != self.height) {
                self.width = new_w;
                self.height = new_h;
                // Recreate SHM buffer for new size
                self.destroyShmBuffer();
                self.createShmBuffer(new_w, new_h) catch {};
                return .{ .resize = .{ .width = new_w, .height = new_h } };
            }
        }

        // Return queued keyboard/focus events
        return self.state.popEvent();
    }

    pub fn putFramebuffer(self: *WaylandWindow, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        if (self.shm_data == null or self.buffer == null) return;

        const blit_w = @min(fb_width, self.buf_width);
        const blit_h = @min(fb_height, self.buf_height);
        if (blit_w == 0 or blit_h == 0) return;

        const dst_stride = self.buf_width;

        // Copy pixels into SHM buffer, row by row
        var y: u32 = 0;
        while (y < blit_h) : (y += 1) {
            const src_offset = y * fb_width;
            const dst_offset = y * dst_stride;
            const src_row = pixels[src_offset..][0..blit_w];
            const dst: [*]u32 = @ptrCast(@alignCast(self.shm_data.?));
            @memcpy(dst[dst_offset..][0..blit_w], src_row);
        }

        // Attach, damage, commit
        c.wl_surface_attach(self.surface, self.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(blit_w), @intCast(blit_h));
        c.wl_surface_commit(self.surface);
        _ = c.wl_display_flush(self.display);
    }

    pub fn getSize(self: *const WaylandWindow) platform.Size {
        return .{ .width = self.width, .height = self.height };
    }

    // ── SHM buffer management ──────────────────────────────────────────

    fn createShmBuffer(self: *WaylandWindow, width: u32, height: u32) !void {
        const shm = self.state.shm orelse return error.WaylandNoShm;
        const stride: u32 = width * 4;
        const size: usize = @as(usize, stride) * @as(usize, height);

        // Create anonymous file via memfd_create
        const fd = memfdCreate("teru-shm");
        if (fd < 0) return error.MemfdCreateFailed;
        errdefer std.posix.close(fd);

        // Set size
        std.posix.ftruncate(fd, @intCast(size)) catch return error.FtruncateFailed;

        // mmap the buffer
        const mapped = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.MmapFailed;

        // Create wl_shm_pool and wl_buffer
        const pool: *c.wl_shm_pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse {
            std.posix.munmap(mapped);
            return error.ShmPoolCreateFailed;
        };

        const buffer: *c.wl_buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse {
            c.wl_shm_pool_destroy(pool);
            std.posix.munmap(mapped);
            return error.BufferCreateFailed;
        };

        // Pool can be destroyed after buffer creation
        c.wl_shm_pool_destroy(pool);

        self.buffer = buffer;
        self.shm_fd = fd;
        self.shm_data = @ptrCast(mapped.ptr);
        self.shm_size = size;
        self.buf_width = width;
        self.buf_height = height;

        // Zero-fill (transparent black)
        @memset(mapped, 0);
    }

    fn destroyShmBuffer(self: *WaylandWindow) void {
        if (self.buffer) |buf| {
            c.wl_buffer_destroy(buf);
            self.buffer = null;
        }
        if (self.shm_data) |data| {
            const slice: []align(4096) u8 = @as([*]align(4096) u8, @ptrCast(data))[0..self.shm_size];
            std.posix.munmap(slice);
            self.shm_data = null;
        }
        if (self.shm_fd >= 0) {
            std.posix.close(self.shm_fd);
            self.shm_fd = -1;
        }
        self.shm_size = 0;
        self.buf_width = 0;
        self.buf_height = 0;
    }
};

// ── memfd_create via libc ───────────────────────────────────────────────

fn memfdCreate(name: [*:0]const u8) std.posix.fd_t {
    const fd = std.c.memfd_create(name, MFD_CLOEXEC);
    if (fd < 0) return -1;
    return fd;
}

// ── Wayland listener implementations ───────────────────────────────────

// Registry listener: bind to compositor, xdg_wm_base, shm, seat
const registry_listener = c.wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    iface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    const interface_str = iface orelse return;
    const reg = registry orelse return;

    if (cStrEql(interface_str, c.wl_compositor_interface.name.?)) {
        state.compositor = @ptrCast(c.wl_registry_bind(
            reg,
            name,
            &c.wl_compositor_interface,
            @min(version, 4),
        ));
    } else if (cStrEql(interface_str, c.xdg_wm_base_interface.name.?)) {
        state.xdg_wm_base = @ptrCast(c.wl_registry_bind(
            reg,
            name,
            &c.xdg_wm_base_interface,
            @min(version, 2),
        ));
    } else if (cStrEql(interface_str, c.wl_shm_interface.name.?)) {
        state.shm = @ptrCast(c.wl_registry_bind(
            reg,
            name,
            &c.wl_shm_interface,
            @min(version, 1),
        ));
    } else if (cStrEql(interface_str, c.wl_seat_interface.name.?)) {
        state.seat = @ptrCast(c.wl_registry_bind(
            reg,
            name,
            &c.wl_seat_interface,
            @min(version, 5),
        ));
    }
}

fn registryGlobalRemove(
    _: ?*anyopaque,
    _: ?*c.wl_registry,
    _: u32,
) callconv(.c) void {}

// xdg_wm_base listener: respond to pings
const xdg_wm_base_listener = c.xdg_wm_base_listener{
    .ping = &xdgWmBasePing,
};

fn xdgWmBasePing(
    _: ?*anyopaque,
    wm_base: ?*c.struct_xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    if (wm_base) |wm| {
        c.xdg_wm_base_pong(wm, serial);
    }
}

// xdg_surface listener: ack configure
const xdg_surface_listener = c.xdg_surface_listener{
    .configure = &xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*c.struct_xdg_surface,
    serial: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    if (xdg_surface) |xs| {
        c.xdg_surface_ack_configure(xs, serial);
    }
    state.configured = true;
}

// xdg_toplevel listener: configure (resize) + close
const xdg_toplevel_listener = c.xdg_toplevel_listener{
    .configure = &xdgToplevelConfigure,
    .close = &xdgToplevelClose,
    .configure_bounds = &xdgToplevelConfigureBounds,
    .wm_capabilities = &xdgToplevelWmCapabilities,
};

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    _: ?*c.wl_array,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    // Width/height of 0 means "client decides"
    if (width > 0) state.pending_width = @intCast(width);
    if (height > 0) state.pending_height = @intCast(height);
}

fn xdgToplevelClose(
    data: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.close_requested = true;
}

fn xdgToplevelConfigureBounds(
    _: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
    _: i32,
    _: i32,
) callconv(.c) void {}

fn xdgToplevelWmCapabilities(
    _: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
    _: ?*c.wl_array,
) callconv(.c) void {}

// wl_seat listener: get keyboard when capability is announced
const seat_listener = c.wl_seat_listener{
    .capabilities = &seatCapabilities,
    .name = &seatName,
};

fn seatCapabilities(
    data: ?*anyopaque,
    seat: ?*c.wl_seat,
    caps: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    const has_keyboard = (caps & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;

    if (has_keyboard and state.keyboard == null) {
        if (seat) |s| {
            state.keyboard = c.wl_seat_get_keyboard(s);
            if (state.keyboard) |kb| {
                _ = c.wl_keyboard_add_listener(kb, &keyboard_listener, data);
            }
        }
    } else if (!has_keyboard and state.keyboard != null) {
        c.wl_keyboard_destroy(state.keyboard.?);
        state.keyboard = null;
    }
}

fn seatName(
    _: ?*anyopaque,
    _: ?*c.wl_seat,
    _: ?[*:0]const u8,
) callconv(.c) void {}

// wl_keyboard listener: key press/release + focus
const keyboard_listener = c.wl_keyboard_listener{
    .keymap = &keyboardKeymap,
    .enter = &keyboardEnter,
    .leave = &keyboardLeave,
    .key = &keyboardKey,
    .modifiers = &keyboardModifiers,
    .repeat_info = &keyboardRepeatInfo,
};

fn keyboardKeymap(
    _: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    fd: i32,
    _: u32,
) callconv(.c) void {
    // Close the keymap fd — we pass raw keycodes for now (xkbcommon later)
    if (fd >= 0) std.posix.close(@intCast(fd));
}

fn keyboardEnter(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    _: ?*c.wl_surface,
    _: ?*c.wl_array,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.has_focus = true;
    state.pushEvent(.focus_in);
}

fn keyboardLeave(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    _: ?*c.wl_surface,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.has_focus = false;
    state.pushEvent(.focus_out);
}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    key_state: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    // Wayland keycodes are evdev codes. Add 8 to match X11 keycode space
    // (X11 keycodes = evdev + 8). This keeps compatibility with the X11 backend.
    const keycode = key + 8;
    const mods = state.mods_depressed;

    if (key_state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        state.pushEvent(.{ .key_press = .{ .keycode = keycode, .modifiers = mods } });
    } else if (key_state == c.WL_KEYBOARD_KEY_STATE_RELEASED) {
        state.pushEvent(.{ .key_release = .{ .keycode = keycode, .modifiers = mods } });
    }
}

fn keyboardModifiers(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    mods_depressed: u32,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.mods_depressed = mods_depressed;
}

fn keyboardRepeatInfo(
    _: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: i32,
    _: i32,
) callconv(.c) void {}

// ── Utility ────────────────────────────────────────────────────────────

fn cStrEql(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return a[i] == b[i];
}
