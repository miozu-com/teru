const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Grid = @import("core/Grid.zig");
const VtParser = @import("core/VtParser.zig");
const Pane = @import("core/Pane.zig");
const Multiplexer = @import("core/Multiplexer.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const Session = @import("persist/Session.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");
const protocol = @import("agent/protocol.zig");
const build_options = @import("build_options");
const Keyboard = if (builtin.os.tag == .linux and build_options.enable_x11)
    @import("platform/linux/keyboard.zig").Keyboard
else
    void;

const version = "0.1.0";

fn out(msg: []const u8) void {
    _ = posix.write(posix.STDOUT_FILENO, msg) catch {};
}

fn outFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch return;
    out(msg);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        var buf: [64]u8 = undefined;
        outFmt(&buf, "teru {s}\n", .{version});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help       Show this help\n  --version    Show version\n  --raw        Raw passthrough mode (no window)\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane\n  x     Close active pane\n  n     Focus next pane\n  p     Focus prev pane\n  1-9   Switch workspace\n  Space Cycle layout\n  d     Detach (save session, exit)\n\n");
        return;
    }

    // Detect rendering tier
    const tier = render.detectTier();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--raw")) {
        return runRawMode(allocator);
    }
    if (tier == .tty) {
        return runRawMode(allocator); // No display server, fall back to TTY
    }
    return runWindowedMode(allocator);
}

// ── Prefix key state ──────────────────────────────────────────────

const PrefixState = struct {
    awaiting: bool = false,
    timestamp_ns: i128 = 0,

    const TIMEOUT_NS: i128 = 1_000_000_000; // 1 second

    fn activate(self: *PrefixState) void {
        self.awaiting = true;
        self.timestamp_ns = std.time.nanoTimestamp();
    }

    fn isExpired(self: *const PrefixState) bool {
        if (!self.awaiting) return false;
        const elapsed = std.time.nanoTimestamp() - self.timestamp_ns;
        return elapsed > TIMEOUT_NS;
    }

    fn reset(self: *PrefixState) void {
        self.awaiting = false;
    }
};

fn runWindowedMode(allocator: std.mem.Allocator) !void {
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(960, 640, "teru");
    defer win.deinit();

    var atlas = try render.FontAtlas.init(allocator, null, 16);
    defer atlas.deinit();

    // CPU SIMD renderer — no GPU needed
    var renderer = try render.tier.Renderer.initCpu(allocator, 960, 640, atlas.cell_width, atlas.cell_height);
    defer renderer.deinit();
    renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);

    const grid_cols: u16 = @intCast(960 / atlas.cell_width);
    const grid_rows: u16 = @intCast(640 / atlas.cell_height);

    // Multiplexer: manages all panes
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();

    // Spawn initial pane
    const initial_id = try mux.spawnPane(grid_rows, grid_cols);
    if (mux.getPaneById(initial_id)) |pane| {
        _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid });
    }

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    var keyboard = if (Keyboard != void)
        Keyboard.init() catch null
    else
        null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var prefix = PrefixState{};
    var pty_buf: [8192]u8 = undefined;
    var running = true;

    while (running) {
        // Check prefix timeout
        if (prefix.isExpired()) {
            prefix.reset();
        }

        while (win.pollEvents()) |event| {
            switch (event) {
                .close => running = false,
                .resize => |sz| {
                    // Resize renderer
                    renderer.resize(sz.width, sz.height);

                    // Recalculate grid dimensions for each pane
                    const new_cols: u16 = @intCast(sz.width / atlas.cell_width);
                    const new_rows: u16 = @intCast(sz.height / atlas.cell_height);

                    // Resize all panes in the active workspace
                    // In multi-pane mode, panes share the screen — each gets
                    // a portion. For simplicity, resize all to the max grid
                    // size and let renderAll handle clipping via layout rects.
                    for (mux.panes.items) |*pane| {
                        if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                            pane.resize(allocator, new_rows, new_cols) catch continue;
                        }
                    }
                },
                .key_press => |key| {
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            var key_buf: [32]u8 = undefined;
                            const len = kb.processKey(key.keycode, true, &key_buf);

                            // Check for Ctrl+Space (prefix key)
                            if (len == 1 and key_buf[0] == 0) {
                                // NUL byte = Ctrl+Space
                                prefix.activate();
                                continue;
                            }

                            if (prefix.awaiting) {
                                prefix.reset();
                                if (len > 0) {
                                    handleMuxCommand(key_buf[0], &mux, &graph, &running, allocator, grid_rows, grid_cols);
                                    continue;
                                }
                            }

                            // Normal key — forward to active pane's PTY
                            if (len > 0) {
                                if (mux.getActivePane()) |pane| {
                                    _ = pane.pty.write(key_buf[0..len]) catch {};
                                }
                            }
                        }
                    } else {
                        // Fallback: raw keycode passthrough (no xkbcommon)
                        if (prefix.awaiting) {
                            prefix.reset();
                            if (key.keycode < 128) {
                                handleMuxCommand(@truncate(key.keycode), &mux, &graph, &running, allocator, grid_rows, grid_cols);
                                continue;
                            }
                        }
                        if (key.keycode < 128) {
                            if (mux.getActivePane()) |pane| {
                                const byte = [1]u8{@truncate(key.keycode)};
                                _ = pane.pty.write(&byte) catch {};
                            }
                        }
                    }
                },
                .key_release => |key| {
                    // Update xkbcommon modifier state on key release
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            var dummy: [1]u8 = undefined;
                            _ = kb.processKey(key.keycode, false, &dummy);
                        }
                    }
                },
                else => {},
            }
        }

        // Poll all PTYs
        const had_output = mux.pollPtys(&pty_buf);

        // Check for agent protocol events on all panes
        for (mux.panes.items) |*pane| {
            if (pane.vt.consumeAgentEvent()) |payload| {
                if (protocol.parsePayload(payload)) |event_data| {
                    switch (event_data.command) {
                        .start => {
                            _ = graph.spawn(.{
                                .name = event_data.name orelse "agent",
                                .kind = .agent,
                                .pid = null,
                            }) catch {};
                        },
                        else => {},
                    }
                }
            }
        }

        // Check if any pane's grid is dirty
        var any_dirty = had_output;
        if (!any_dirty) {
            for (mux.panes.items) |*pane| {
                if (pane.grid.dirty) {
                    any_dirty = true;
                    break;
                }
            }
        }

        if (any_dirty) {
            // Get the underlying SoftwareRenderer for multi-pane rendering
            switch (renderer) {
                .cpu => |*cpu| {
                    const sz = win.getSize();
                    mux.renderAll(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height);
                    win.putFramebuffer(cpu.getFramebuffer(), sz.width, sz.height);
                },
                .tty => {},
            }
            // Clear dirty flags
            for (mux.panes.items) |*pane| {
                pane.grid.dirty = false;
            }
        } else {
            std.Thread.sleep(1_000_000); // 1ms idle
        }
    }
}

/// Handle a multiplexer command after the prefix key (Ctrl+Space).
fn handleMuxCommand(
    cmd: u8,
    mux: *Multiplexer,
    graph: *ProcessGraph,
    running: *bool,
    allocator: std.mem.Allocator,
    grid_rows: u16,
    grid_cols: u16,
) void {
    switch (cmd) {
        'c' => {
            // Spawn new pane
            const id = mux.spawnPane(grid_rows, grid_cols) catch return;
            if (mux.getPaneById(id)) |pane| {
                _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid }) catch {};
            }
        },
        'x' => {
            // Close active pane
            if (mux.getActivePane()) |pane| {
                const id = pane.id;
                mux.closePane(id);
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
            mux.saveSession(graph, "/tmp/teru-session.bin") catch {};
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
    _ = allocator;
}

fn runRawMode(allocator: std.mem.Allocator) !void {
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var terminal = Terminal.init();
    defer terminal.deinit();

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty.deinit();

    const node_id = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pty.child_pid });

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0x10000000,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    g_pty_master_fd = pty.master;
    g_host_fd = terminal.host_fd;

    try terminal.enterRawMode();
    out("\x1b[2J\x1b[H");
    terminal.runLoop(&pty) catch {};
    terminal.exitRawMode();

    if (pty.child_pid != null) {
        const status = pty.waitForExit() catch 0;
        graph.markFinished(node_id, @truncate(status >> 8));
    }
    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s)\n", .{graph.nodeCount()});
}

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

fn handleSigwinch(_: c_int) callconv(.c) void {
    if (g_pty_master_fd < 0) return;
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return;
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}
