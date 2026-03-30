//! X11 backend using XCB for event handling + EGL for the OpenGL context.
//!
//! Creates an X11 window via XCB, sets EWMH properties (_NET_WM_NAME,
//! WM_CLASS, WM_DELETE_WINDOW), and attaches an EGL OpenGL 4.3 core
//! context to it.

const std = @import("std");
const platform = @import("platform.zig");

pub const Event = platform.Event;
pub const KeyEvent = platform.KeyEvent;

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("EGL/egl.h");
});

// ── X11 Window ──────────────────────────────────────────────────

pub const X11Window = struct {
    display: *c.Display,
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    screen: *c.xcb_screen_t,
    egl_display: c.EGLDisplay,
    egl_surface: c.EGLSurface,
    egl_context: c.EGLContext,
    width: u32,
    height: u32,
    is_open: bool,
    wm_delete_window: c.xcb_atom_t,
    wm_protocols: c.xcb_atom_t,

    // ── lifecycle ───────────────────────────────────────────────

    pub fn init(width: u32, height: u32, title: []const u8) !X11Window {
        // 1. Open X11 display
        const display = c.XOpenDisplay(null) orelse return error.X11DisplayOpenFailed;

        // 2. Get XCB connection from the Xlib display
        const connection = c.XGetXCBConnection(display) orelse {
            _ = c.XCloseDisplay(display);
            return error.XcbConnectionFailed;
        };

        // Tell Xlib to let XCB own the event queue
        c.XSetEventQueueOwner(display, c.XCBOwnsEventQueue);

        // 3. Get the default screen
        const setup = c.xcb_get_setup(connection);
        const screen_iter = c.xcb_setup_roots_iterator(setup);
        const screen: *c.xcb_screen_t = screen_iter.data orelse {
            _ = c.XCloseDisplay(display);
            return error.XcbNoScreen;
        };

        // 4. Create window
        const win_id = c.xcb_generate_id(connection);

        const event_mask: u32 = c.XCB_EVENT_MASK_EXPOSURE |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_FOCUS_CHANGE;

        const value_mask: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK;
        const value_list = [2]u32{ screen.black_pixel, event_mask };

        _ = c.xcb_create_window(
            connection,
            c.XCB_COPY_FROM_PARENT, // depth
            win_id,
            screen.root,
            0,
            0, // x, y
            @intCast(width),
            @intCast(height),
            0, // border_width
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            value_mask,
            &value_list,
        );

        // 5. WM_CLASS (instance + class, NUL separated, for WM matching)
        const wm_class = "teru\x00teru\x00";
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            win_id,
            c.XCB_ATOM_WM_CLASS,
            c.XCB_ATOM_STRING,
            8,
            wm_class.len,
            wm_class.ptr,
        );

        // 6. _NET_WM_NAME (EWMH title — UTF-8)
        const utf8_string_atom = internAtom(connection, "UTF8_STRING", false);
        const net_wm_name_atom = internAtom(connection, "_NET_WM_NAME", false);

        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            win_id,
            net_wm_name_atom,
            utf8_string_atom,
            8,
            @intCast(title.len),
            title.ptr,
        );

        // Also set the legacy WM_NAME for older WMs
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            win_id,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );

        // 7. WM_PROTOCOLS + WM_DELETE_WINDOW
        const wm_protocols_atom = internAtom(connection, "WM_PROTOCOLS", false);
        const wm_delete_atom = internAtom(connection, "WM_DELETE_WINDOW", false);

        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            win_id,
            wm_protocols_atom,
            c.XCB_ATOM_ATOM,
            32,
            1,
            @as(*const u32, &wm_delete_atom),
        );

        // 8. Initialize EGL
        const egl_display = c.eglGetDisplay(@ptrCast(display));
        if (egl_display == c.EGL_NO_DISPLAY) {
            _ = c.XCloseDisplay(display);
            return error.EglGetDisplayFailed;
        }

        var egl_major: c.EGLint = 0;
        var egl_minor: c.EGLint = 0;
        if (c.eglInitialize(egl_display, &egl_major, &egl_minor) == c.EGL_FALSE) {
            _ = c.XCloseDisplay(display);
            return error.EglInitializeFailed;
        }

        if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) {
            _ = c.eglTerminate(egl_display);
            _ = c.XCloseDisplay(display);
            return error.EglBindApiFailed;
        }

        // Choose EGL config: RGBA8, no depth, renderable with OpenGL
        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_DEPTH_SIZE,      0,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_NONE,
        };

        var egl_config: c.EGLConfig = null;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(egl_display, &config_attribs, &egl_config, 1, &num_configs) == c.EGL_FALSE or num_configs == 0) {
            _ = c.eglTerminate(egl_display);
            _ = c.XCloseDisplay(display);
            return error.EglChooseConfigFailed;
        }

        // Create OpenGL 4.3 core context
        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 4,
            c.EGL_CONTEXT_MINOR_VERSION, 3,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };

        const egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &context_attribs);
        if (egl_context == c.EGL_NO_CONTEXT) {
            _ = c.eglTerminate(egl_display);
            _ = c.XCloseDisplay(display);
            return error.EglCreateContextFailed;
        }

        // Create EGL window surface
        const egl_surface = c.eglCreateWindowSurface(egl_display, egl_config, @intCast(win_id), null);
        if (egl_surface == c.EGL_NO_SURFACE) {
            _ = c.eglDestroyContext(egl_display, egl_context);
            _ = c.eglTerminate(egl_display);
            _ = c.XCloseDisplay(display);
            return error.EglCreateSurfaceFailed;
        }

        // 9. Make EGL context current
        if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) == c.EGL_FALSE) {
            _ = c.eglDestroySurface(egl_display, egl_surface);
            _ = c.eglDestroyContext(egl_display, egl_context);
            _ = c.eglTerminate(egl_display);
            _ = c.XCloseDisplay(display);
            return error.EglMakeCurrentFailed;
        }

        // 10. Map the window
        _ = c.xcb_map_window(connection, win_id);
        _ = c.xcb_flush(connection);

        return X11Window{
            .display = display,
            .connection = connection,
            .window = win_id,
            .screen = screen,
            .egl_display = egl_display,
            .egl_surface = egl_surface,
            .egl_context = egl_context,
            .width = width,
            .height = height,
            .is_open = true,
            .wm_delete_window = wm_delete_atom,
            .wm_protocols = wm_protocols_atom,
        };
    }

    pub fn deinit(self: *X11Window) void {
        if (self.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.egl_surface != c.EGL_NO_SURFACE) {
                _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
            }
            if (self.egl_context != c.EGL_NO_CONTEXT) {
                _ = c.eglDestroyContext(self.egl_display, self.egl_context);
            }
            _ = c.eglTerminate(self.egl_display);
        }

        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);

        // XCloseDisplay also closes the XCB connection
        _ = c.XCloseDisplay(self.display);

        self.is_open = false;
    }

    // ── events ──────────────────────────────────────────────────

    pub fn pollEvents(self: *X11Window) ?Event {
        const raw_event = c.xcb_poll_for_event(self.connection) orelse return null;
        defer std.c.free(raw_event);

        // Mask off the sent-event bit (bit 7)
        const response_type: u8 = raw_event.*.response_type & 0x7f;

        switch (response_type) {
            c.XCB_EXPOSE => {
                return .expose;
            },
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
                return .{ .key_press = .{
                    .keycode = @intCast(key.detail),
                    .modifiers = @intCast(key.state),
                } };
            },
            c.XCB_KEY_RELEASE => {
                const key: *const c.xcb_key_release_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .key_release = .{
                    .keycode = @intCast(key.detail),
                    .modifiers = @intCast(key.state),
                } };
            },
            c.XCB_CLIENT_MESSAGE => {
                const msg: *const c.xcb_client_message_event_t = @ptrCast(@alignCast(raw_event));
                if (msg.data.data32[0] == self.wm_delete_window) {
                    self.is_open = false;
                    return .close;
                }
                return .none;
            },
            c.XCB_FOCUS_IN => {
                return .focus_in;
            },
            c.XCB_FOCUS_OUT => {
                return .focus_out;
            },
            else => {
                return .none;
            },
        }
    }

    // ── rendering ───────────────────────────────────────────────

    pub fn swapBuffers(self: *X11Window) void {
        _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
    }

    pub fn getSize(self: *const X11Window) struct { width: u32, height: u32 } {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
        const addr = c.eglGetProcAddress(name);
        return @ptrCast(addr);
    }
};

// ── helpers ─────────────────────────────────────────────────────

/// Intern an X11 atom by name.  Blocks until the server replies.
fn internAtom(conn: *c.xcb_connection_t, name: [*:0]const u8, only_if_exists: bool) c.xcb_atom_t {
    const name_len: u16 = @intCast(std.mem.len(name));
    const cookie = c.xcb_intern_atom(conn, @intFromBool(only_if_exists), name_len, name);
    const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return c.XCB_ATOM_NONE;
    defer std.c.free(reply);
    return reply.*.atom;
}
