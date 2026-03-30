//! X11 backend using pure XCB. No Xlib, no EGL, no OpenGL.
//!
//! Creates a window, sets EWMH properties, handles events,
//! blits CPU framebuffer via xcb_put_image. Single dependency: libxcb.

const std = @import("std");
const platform = @import("platform.zig");

pub const Event = platform.Event;
pub const KeyEvent = platform.KeyEvent;

const c = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const X11Window = struct {
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    screen: *c.xcb_screen_t,
    gc: c.xcb_gcontext_t,
    width: u32,
    height: u32,
    is_open: bool,
    wm_delete_window: c.xcb_atom_t,
    depth: u8,

    pub fn init(width: u32, height: u32, title: []const u8) !X11Window {
        // Connect to X server (pure XCB, no Xlib)
        var screen_num: c_int = 0;
        const connection = c.xcb_connect(null, &screen_num) orelse return error.XcbConnectFailed;
        if (c.xcb_connection_has_error(connection) != 0) {
            c.xcb_disconnect(connection);
            return error.XcbConnectionError;
        }

        // Get default screen
        const setup = c.xcb_get_setup(connection);
        var iter = c.xcb_setup_roots_iterator(setup);
        var i: c_int = 0;
        while (i < screen_num) : (i += 1) {
            c.xcb_screen_next(&iter);
        }
        const screen: *c.xcb_screen_t = iter.data orelse {
            c.xcb_disconnect(connection);
            return error.XcbNoScreen;
        };

        // Create window
        const win_id = c.xcb_generate_id(connection);
        const event_mask: u32 = c.XCB_EVENT_MASK_EXPOSURE |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_FOCUS_CHANGE;
        const value_mask: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK;
        const value_list = [2]u32{ screen.black_pixel, event_mask };

        _ = c.xcb_create_window(connection, c.XCB_COPY_FROM_PARENT, win_id, screen.root, 0, 0, @intCast(width), @intCast(height), 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, value_mask, &value_list);

        // Graphics context
        const gc = c.xcb_generate_id(connection);
        _ = c.xcb_create_gc(connection, gc, win_id, 0, null);

        // WM_CLASS
        const wm_class = "teru\x00teru\x00";
        _ = c.xcb_change_property(connection, c.XCB_PROP_MODE_REPLACE, win_id, c.XCB_ATOM_WM_CLASS, c.XCB_ATOM_STRING, 8, wm_class.len, wm_class.ptr);

        // _NET_WM_NAME (EWMH)
        const utf8_atom = internAtom(connection, "UTF8_STRING", false);
        const net_wm_name = internAtom(connection, "_NET_WM_NAME", false);
        _ = c.xcb_change_property(connection, c.XCB_PROP_MODE_REPLACE, win_id, net_wm_name, utf8_atom, 8, @intCast(title.len), title.ptr);
        _ = c.xcb_change_property(connection, c.XCB_PROP_MODE_REPLACE, win_id, c.XCB_ATOM_WM_NAME, c.XCB_ATOM_STRING, 8, @intCast(title.len), title.ptr);

        // WM_PROTOCOLS + WM_DELETE_WINDOW
        const wm_protocols = internAtom(connection, "WM_PROTOCOLS", false);
        const wm_delete = internAtom(connection, "WM_DELETE_WINDOW", false);
        _ = c.xcb_change_property(connection, c.XCB_PROP_MODE_REPLACE, win_id, wm_protocols, c.XCB_ATOM_ATOM, 32, 1, @as(*const u32, &wm_delete));

        // Map window
        _ = c.xcb_map_window(connection, win_id);
        _ = c.xcb_flush(connection);

        return X11Window{
            .connection = connection,
            .window = win_id,
            .screen = screen,
            .gc = gc,
            .width = width,
            .height = height,
            .is_open = true,
            .wm_delete_window = wm_delete,
            .depth = screen.root_depth,
        };
    }

    pub fn deinit(self: *X11Window) void {
        _ = c.xcb_free_gc(self.connection, self.gc);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);
        c.xcb_disconnect(self.connection);
        self.is_open = false;
    }

    pub fn pollEvents(self: *X11Window) ?Event {
        const raw_event = c.xcb_poll_for_event(self.connection) orelse return null;
        defer std.c.free(raw_event);
        const response_type: u8 = raw_event.*.response_type & 0x7f;

        return switch (response_type) {
            c.XCB_EXPOSE => .expose,
            c.XCB_CONFIGURE_NOTIFY => {
                const cfg: *const c.xcb_configure_notify_event_t = @ptrCast(@alignCast(raw_event));
                const new_w: u32 = @intCast(cfg.width);
                const new_h: u32 = @intCast(cfg.height);
                if (new_w != self.width or new_h != self.height) {
                    self.width = new_w;
                    self.height = new_h;
                    return .{ .resize = .{ .width = new_w, .height = new_h } };
                }
                return .none;
            },
            c.XCB_KEY_PRESS => {
                const key: *const c.xcb_key_press_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .key_press = .{ .keycode = @intCast(key.detail), .modifiers = @intCast(key.state) } };
            },
            c.XCB_KEY_RELEASE => {
                const key: *const c.xcb_key_release_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .key_release = .{ .keycode = @intCast(key.detail), .modifiers = @intCast(key.state) } };
            },
            c.XCB_CLIENT_MESSAGE => {
                const msg: *const c.xcb_client_message_event_t = @ptrCast(@alignCast(raw_event));
                if (msg.data.data32[0] == self.wm_delete_window) {
                    self.is_open = false;
                    return .close;
                }
                return .none;
            },
            c.XCB_FOCUS_IN => .focus_in,
            c.XCB_FOCUS_OUT => .focus_out,
            else => .none,
        };
    }

    pub fn putFramebuffer(self: *X11Window, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.width);
        const blit_h = @min(fb_height, self.height);
        if (blit_w == 0 or blit_h == 0) return;

        const data: [*]const u8 = @ptrCast(pixels.ptr);
        const row_bytes = fb_width * 4;

        _ = c.xcb_put_image(self.connection, c.XCB_IMAGE_FORMAT_Z_PIXMAP, self.window, self.gc, @intCast(blit_w), @intCast(blit_h), 0, 0, 0, self.depth, blit_h * row_bytes, data);
        _ = c.xcb_flush(self.connection);
    }

    pub fn getSize(self: *const X11Window) platform.Size {
        return .{ .width = self.width, .height = self.height };
    }
};

fn internAtom(conn: *c.xcb_connection_t, name: [*:0]const u8, only_if_exists: bool) c.xcb_atom_t {
    const name_len: u16 = @intCast(std.mem.len(name));
    const cookie = c.xcb_intern_atom(conn, @intFromBool(only_if_exists), name_len, name);
    const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return c.XCB_ATOM_NONE;
    defer std.c.free(reply);
    return reply.*.atom;
}
