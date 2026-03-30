//! Keyboard input translation via xkbcommon.
//! Converts raw XCB keycodes to UTF-8 text and named keys.

const std = @import("std");

// ── xkbcommon externs (extern linkage against libxkbcommon) ─────────

const xkb_context = opaque {};
const xkb_keymap = opaque {};
const xkb_state = opaque {};
const xkb_keycode_t = u32;
const xkb_keysym_t = u32;

extern "xkbcommon" fn xkb_context_new(flags: u32) callconv(.c) ?*xkb_context;
extern "xkbcommon" fn xkb_context_unref(ctx: *xkb_context) callconv(.c) void;
extern "xkbcommon" fn xkb_keymap_new_from_names(ctx: *xkb_context, names: ?*const anyopaque, flags: u32) callconv(.c) ?*xkb_keymap;
extern "xkbcommon" fn xkb_keymap_unref(keymap: *xkb_keymap) callconv(.c) void;
extern "xkbcommon" fn xkb_state_new(keymap: *xkb_keymap) callconv(.c) ?*xkb_state;
extern "xkbcommon" fn xkb_state_unref(state: *xkb_state) callconv(.c) void;
extern "xkbcommon" fn xkb_state_key_get_utf8(state: *xkb_state, key: xkb_keycode_t, buf: [*]u8, size: usize) callconv(.c) c_int;
extern "xkbcommon" fn xkb_state_key_get_one_sym(state: *xkb_state, key: xkb_keycode_t) callconv(.c) xkb_keysym_t;
extern "xkbcommon" fn xkb_state_update_key(state: *xkb_state, key: xkb_keycode_t, direction: u32) callconv(.c) u32;

// ── XKB key direction ──────────────────────────────────────────────

const XKB_KEY_DOWN: u32 = 1;
const XKB_KEY_UP: u32 = 0;

// ── Common keysyms ─────────────────────────────────────────────────

const XKB_KEY_Return: u32 = 0xff0d;
const XKB_KEY_BackSpace: u32 = 0xff08;
const XKB_KEY_Tab: u32 = 0xff09;
const XKB_KEY_Escape: u32 = 0xff1b;
const XKB_KEY_Delete: u32 = 0xffff;
const XKB_KEY_Up: u32 = 0xff52;
const XKB_KEY_Down: u32 = 0xff54;
const XKB_KEY_Right: u32 = 0xff53;
const XKB_KEY_Left: u32 = 0xff51;
const XKB_KEY_Home: u32 = 0xff50;
const XKB_KEY_End: u32 = 0xff57;
const XKB_KEY_Page_Up: u32 = 0xff55;
const XKB_KEY_Page_Down: u32 = 0xff56;
const XKB_KEY_Insert: u32 = 0xff63;
const XKB_KEY_F1: u32 = 0xffbe;
const XKB_KEY_F2: u32 = 0xffbf;
const XKB_KEY_F3: u32 = 0xffc0;
const XKB_KEY_F4: u32 = 0xffc1;
const XKB_KEY_F5: u32 = 0xffc2;
const XKB_KEY_F6: u32 = 0xffc3;
const XKB_KEY_F7: u32 = 0xffc4;
const XKB_KEY_F8: u32 = 0xffc5;
const XKB_KEY_F9: u32 = 0xffc6;
const XKB_KEY_F10: u32 = 0xffc7;
const XKB_KEY_F11: u32 = 0xffc8;
const XKB_KEY_F12: u32 = 0xffc9;

pub const Keyboard = struct {
    ctx: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,

    pub fn init() !Keyboard {
        const ctx = xkb_context_new(0) orelse return error.XkbContextFailed;
        errdefer xkb_context_unref(ctx);

        const keymap = xkb_keymap_new_from_names(ctx, null, 0) orelse {
            return error.XkbKeymapFailed;
        };
        errdefer xkb_keymap_unref(keymap);

        const state = xkb_state_new(keymap) orelse {
            return error.XkbStateFailed;
        };

        return .{ .ctx = ctx, .keymap = keymap, .state = state };
    }

    pub fn deinit(self: *Keyboard) void {
        xkb_state_unref(self.state);
        xkb_keymap_unref(self.keymap);
        xkb_context_unref(self.ctx);
    }

    /// Translate a raw XCB keycode to bytes for the PTY.
    /// XCB keycodes are evdev + 8, which is what xkbcommon expects.
    /// Returns the number of bytes written to buf.
    pub fn processKey(self: *Keyboard, keycode: u32, pressed: bool, buf: []u8) usize {
        const xkb_key = keycode;

        if (pressed) {
            _ = xkb_state_update_key(self.state, xkb_key, XKB_KEY_DOWN);
        } else {
            _ = xkb_state_update_key(self.state, xkb_key, XKB_KEY_UP);
            return 0; // Only generate output on key press, not release
        }

        // Check for special keys that produce escape sequences
        const keysym = xkb_state_key_get_one_sym(self.state, xkb_key);
        const special = keysymToEscape(keysym);
        if (special.len > 0) {
            if (special.len <= buf.len) {
                @memcpy(buf[0..special.len], special);
                return special.len;
            }
            return 0;
        }

        // Get UTF-8 text for printable keys
        if (buf.len == 0) return 0;
        const n = xkb_state_key_get_utf8(self.state, xkb_key, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);

        return 0;
    }
};

fn keysymToEscape(keysym: u32) []const u8 {
    return switch (keysym) {
        XKB_KEY_Return => "\r",
        XKB_KEY_BackSpace => "\x7f",
        XKB_KEY_Tab => "\t",
        XKB_KEY_Escape => "\x1b",
        XKB_KEY_Delete => "\x1b[3~",
        XKB_KEY_Up => "\x1b[A",
        XKB_KEY_Down => "\x1b[B",
        XKB_KEY_Right => "\x1b[C",
        XKB_KEY_Left => "\x1b[D",
        XKB_KEY_Home => "\x1b[H",
        XKB_KEY_End => "\x1b[F",
        XKB_KEY_Page_Up => "\x1b[5~",
        XKB_KEY_Page_Down => "\x1b[6~",
        XKB_KEY_Insert => "\x1b[2~",
        XKB_KEY_F1 => "\x1bOP",
        XKB_KEY_F2 => "\x1bOQ",
        XKB_KEY_F3 => "\x1bOR",
        XKB_KEY_F4 => "\x1bOS",
        XKB_KEY_F5 => "\x1b[15~",
        XKB_KEY_F6 => "\x1b[17~",
        XKB_KEY_F7 => "\x1b[18~",
        XKB_KEY_F8 => "\x1b[19~",
        XKB_KEY_F9 => "\x1b[20~",
        XKB_KEY_F10 => "\x1b[21~",
        XKB_KEY_F11 => "\x1b[23~",
        XKB_KEY_F12 => "\x1b[24~",
        else => &.{},
    };
}
