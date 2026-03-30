const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const Pty = @import("pty/Pty.zig");
const Multiplexer = @import("core/Multiplexer.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");
const protocol = @import("agent/protocol.zig");
const build_options = @import("build_options");
const Config = @import("config/Config.zig");
const Hooks = @import("config/Hooks.zig");
const Selection = @import("core/Selection.zig");
const Clipboard = @import("core/Clipboard.zig");
const KeyHandler = @import("core/KeyHandler.zig");
const Keyboard = if (builtin.os.tag == .linux and build_options.enable_x11)
    @import("platform/linux/keyboard.zig").Keyboard
else
    void;

const version = "0.1.0";

fn out(msg: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}

fn outFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch return;
    out(msg);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_alloc.allocator();
    defer _ = debug_alloc.deinit();

    // Parse command line args (0.16: std.process.Args.Iterator replaces argsAlloc)
    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next(); // skip argv[0]
    const first_arg: ?[:0]const u8 = args_iter.next();

    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help       Show this help\n  --version    Show version\n  --raw        Raw passthrough mode (no window)\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane\n  x     Close active pane\n  n     Focus next pane\n  p     Focus prev pane\n  1-9   Switch workspace\n  Space Cycle layout\n  d     Detach (save session, exit)\n\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            return runRawMode(allocator);
        }
    }

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty) {
        return runRawMode(allocator); // No display server, fall back to TTY
    }
    return runWindowedMode(allocator);
}

fn runWindowedMode(allocator: std.mem.Allocator) !void {
    // Load configuration from ~/.config/teru/teru.conf (defaults if missing)
    var config = try Config.load(allocator);
    defer config.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(config.initial_width, config.initial_height, "teru");
    defer win.deinit();

    var atlas = try render.FontAtlas.init(allocator, config.font_path, config.font_size);
    defer atlas.deinit();

    // CPU SIMD renderer — no GPU needed (cursor color from config)
    var renderer = try render.tier.Renderer.initCpuWithCursor(
        allocator,
        config.initial_width,
        config.initial_height,
        atlas.cell_width,
        atlas.cell_height,
        config.cursor_color,
    );
    defer renderer.deinit();
    renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);

    const grid_cols: u16 = @intCast(config.initial_width / atlas.cell_width);
    const grid_rows: u16 = @intCast(config.initial_height / atlas.cell_height);

    // Multiplexer: manages all panes
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();

    // Plugin hooks: external commands fired on terminal events
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();
    loadHooks(&config, &hooks);

    // Spawn initial pane
    const initial_id = try mux.spawnPane(grid_rows, grid_cols);
    if (mux.getPaneById(initial_id)) |pane| {
        _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid });
    }
    hooks.fire(.spawn);

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    var keyboard = if (Keyboard != void)
        Keyboard.init() catch null
    else
        null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var prefix = KeyHandler.PrefixState{};
    var selection = Selection{};
    _ = &selection;
    var mouse_down = false;
    _ = &mouse_down;
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
                                    KeyHandler.handleMuxCommand(key_buf[0], &mux, &graph, &hooks, &running, grid_rows, grid_cols);
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
                                KeyHandler.handleMuxCommand(@truncate(key.keycode), &mux, &graph, &hooks, &running, grid_rows, grid_cols);
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
                .mouse_press => |mouse| {
                    switch (mouse.button) {
                        .left => {
                            // Start text selection
                            const col: u16 = @intCast(mouse.x / atlas.cell_width);
                            const row: u16 = @intCast(mouse.y / atlas.cell_height);
                            selection.clear();
                            selection.begin(row, col);
                            mouse_down = true;
                        },
                        .middle => {
                            // Paste from clipboard
                            if (mux.getActivePane()) |pane| {
                                Clipboard.paste(&pane.pty);
                            }
                        },
                        .scroll_up => {
                            // Scroll up (future: scrollback navigation)
                        },
                        .scroll_down => {
                            // Scroll down (future: scrollback navigation)
                        },
                        else => {},
                    }
                },
                .mouse_release => |mouse| {
                    if (mouse.button == .left and mouse_down) {
                        mouse_down = false;
                        const col: u16 = @intCast(mouse.x / atlas.cell_width);
                        const row: u16 = @intCast(mouse.y / atlas.cell_height);
                        selection.update(row, col);
                        selection.finish();

                        // Copy selected text to clipboard
                        if (mux.getActivePane()) |pane| {
                            var sel_buf: [8192]u8 = undefined;
                            const len = selection.getText(&pane.grid, &sel_buf);
                            if (len > 0) {
                                Clipboard.copy(sel_buf[0..len]);
                            }
                        }
                    }
                },
                .mouse_motion => |motion| {
                    if (mouse_down) {
                        const col: u16 = @intCast(motion.x / atlas.cell_width);
                        const row: u16 = @intCast(motion.y / atlas.cell_height);
                        selection.update(row, col);
                        // Mark grid dirty so selection highlight redraws
                        if (mux.getActivePane()) |pane| {
                            pane.grid.dirty = true;
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
                            hooks.fire(.agent_start);
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
                    const sel_ptr: ?*const Selection = if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr);
                    win.putFramebuffer(cpu.getFramebuffer(), sz.width, sz.height);
                },
                .tty => {},
            }
            // Clear dirty flags
            for (mux.panes.items) |*pane| {
                pane.grid.dirty = false;
            }
        } else {
            // 1ms idle sleep via linux nanosleep (Thread.sleep removed in 0.16)
            const req = linux.timespec{ .sec = 0, .nsec = 1_000_000 };
            _ = linux.nanosleep(&req, null);
        }
    }
}

/// Transfer hook commands from Config into the Hooks struct.
fn loadHooks(config: *const Config, hooks: *Hooks) void {
    if (config.hook_on_spawn) |cmd| hooks.setHook(.spawn, cmd);
    if (config.hook_on_close) |cmd| hooks.setHook(.close, cmd);
    if (config.hook_on_agent_start) |cmd| hooks.setHook(.agent_start, cmd);
    if (config.hook_on_session_save) |cmd| hooks.setHook(.session_save, cmd);
}

fn runRawMode(allocator: std.mem.Allocator) !void {
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var terminal = Terminal.init();
    defer terminal.deinit();

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty_inst = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty_inst.deinit();

    const node_id = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pty_inst.child_pid });

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0x10000000,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    g_pty_master_fd = pty_inst.master;
    g_host_fd = terminal.host_fd;

    try terminal.enterRawMode();
    out("\x1b[2J\x1b[H");
    terminal.runLoop(&pty_inst) catch {};
    terminal.exitRawMode();

    if (pty_inst.child_pid != null) {
        const status = pty_inst.waitForExit() catch 0;
        graph.markFinished(node_id, @truncate(status >> 8));
    }
    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s)\n", .{graph.nodeCount()});
}

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    if (g_pty_master_fd < 0) return;
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return;
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}
