//! Multiplexer key command handling.
//!
//! Contains the prefix-key state machine and mux command dispatch.
//! Extracted from main.zig for modularity — the event loop calls
//! into these helpers rather than inlining the logic.

const std = @import("std");
const Io = std.Io;
const Multiplexer = @import("Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Hooks = @import("../config/Hooks.zig");
const compat = @import("../compat.zig");

// ── Prefix key state ─────────────────────────────────────────────

pub const PrefixState = struct {
    awaiting: bool = false,
    timestamp_ns: i128 = 0,

    const TIMEOUT_NS: i128 = 1_000_000_000; // 1 second

    pub fn activate(self: *PrefixState) void {
        self.awaiting = true;
        self.timestamp_ns = compat.nanoTimestamp();
    }

    pub fn isExpired(self: *const PrefixState) bool {
        if (!self.awaiting) return false;
        const elapsed = compat.nanoTimestamp() - self.timestamp_ns;
        return elapsed > TIMEOUT_NS;
    }

    pub fn reset(self: *PrefixState) void {
        self.awaiting = false;
    }
};

// ── Mux command dispatch ─────────────────────────────────────────

/// Handle a multiplexer command after the prefix key (Ctrl+Space).
pub fn handleMuxCommand(
    cmd: u8,
    mux: *Multiplexer,
    graph: *ProcessGraph,
    hooks: *const Hooks,
    running: *bool,
    grid_rows: u16,
    grid_cols: u16,
    io: Io,
) void {
    switch (cmd) {
        'c' => {
            // Spawn new pane
            const id = mux.spawnPane(grid_rows, grid_cols) catch return;
            if (mux.getPaneById(id)) |pane| {
                // Graph registration failure is non-fatal: pane works without tracking
                _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid }) catch {};
            }
            hooks.fire(.spawn);
        },
        'x' => {
            // Close active pane
            if (mux.getActivePane()) |pane| {
                const id = pane.id;
                mux.closePane(id);
                hooks.fire(.close);
                // If no panes left, exit
                if (mux.panes.items.len == 0) {
                    running.* = false;
                }
            }
        },
        'n' => mux.focusNext(),
        'p' => mux.focusPrev(),
        ' ' => mux.cycleLayout(),
        'd' => {
            // Detach: save session and exit
            mux.saveSession(graph, "/tmp/teru-session.bin", io) catch {
                // Session save failed — still detach (data loss over hang)
            };
            hooks.fire(.session_save);
            running.* = false;
        },
        '1'...'9' => {
            // Switch workspace (1-based → 0-based)
            mux.switchWorkspace(cmd - '1');
        },
        else => {
            // Unknown command; forward the prefix + key to active pane
            if (mux.getActivePane()) |pane| {
                const nul = [1]u8{0}; // Ctrl+Space = NUL
                _ = pane.pty.write(&nul) catch {};
                const byte = [1]u8{cmd};
                _ = pane.pty.write(&byte) catch {};
            }
        },
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "PrefixState init is inactive" {
    const ps = PrefixState{};
    try std.testing.expect(!ps.awaiting);
    try std.testing.expect(!ps.isExpired());
}

test "PrefixState activate and reset" {
    var ps = PrefixState{};
    ps.activate();
    try std.testing.expect(ps.awaiting);
    try std.testing.expect(!ps.isExpired()); // just activated, not expired
    ps.reset();
    try std.testing.expect(!ps.awaiting);
}
