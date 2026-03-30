//! Shared platform event types.
//!
//! Canonical definitions for Event, KeyEvent, and Size used by all
//! platform backends (Linux, macOS, Windows). Each backend re-exports
//! these types instead of defining its own copies.

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
