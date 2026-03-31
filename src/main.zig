const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Multiplexer = @import("core/Multiplexer.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");
const protocol = @import("agent/protocol.zig");
const McpServer = @import("agent/McpServer.zig");
const build_options = @import("build_options");
const Config = @import("config/Config.zig");
const Hooks = @import("config/Hooks.zig");
const Selection = @import("core/Selection.zig");
const Clipboard = @import("core/Clipboard.zig");
const KeyHandler = @import("core/KeyHandler.zig");
const Grid = @import("core/Grid.zig");
const Scrollback = @import("persist/Scrollback.zig");
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Parse command line args
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]
    const first_arg: ?[:0]const u8 = args_iter.next();

    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help       Show this help\n  --version    Show version\n  --raw        Raw passthrough mode (no window)\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane\n  x     Close active pane\n  n     Focus next pane\n  p     Focus prev pane\n  1-9   Switch workspace\n  Space Cycle layout\n  d     Detach (save session, exit)\n\nScrollback:\n  Shift+PageUp    Scroll up one page\n  Shift+PageDown  Scroll down one page\n  Any key         Exit scroll mode\n\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            return runRawMode(allocator, io);
        }
    }

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty) {
        return runRawMode(allocator, io); // No display server, fall back to TTY
    }
    return runWindowedMode(allocator, io);
}

fn runWindowedMode(allocator: std.mem.Allocator, io: std.Io) !void {
    // Load configuration from ~/.config/teru/teru.conf (defaults if missing)
    var config = try Config.load(allocator, io);
    defer config.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(config.initial_width, config.initial_height, "teru");
    defer win.deinit();

    var atlas = try render.FontAtlas.init(allocator, config.font_path, config.font_size, io);
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

    const padding: u32 = 4; // must match SoftwareRenderer.padding
    var grid_cols: u16 = @intCast((config.initial_width -| padding * 2) / atlas.cell_width);
    var grid_rows: u16 = @intCast((config.initial_height -| padding * 2) / atlas.cell_height);

    // Multiplexer: manages all panes (linked to process graph for agent rendering)
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();
    mux.graph = &graph;

    // Plugin hooks: external commands fired on terminal events
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();
    loadHooks(&config, &hooks);

    // MCP server: exposes pane/graph state to Claude Code over Unix socket
    var mcp = McpServer.init(allocator, &mux, &graph) catch null;
    defer if (mcp) |*m| m.deinit();

    // Spawn initial pane
    const initial_id = try mux.spawnPane(grid_rows, grid_cols);
    if (mux.getPaneById(initial_id)) |pane| {
        _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid });
    }
    hooks.fire(.spawn);

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    // Uses the LIVE X11 keymap (supports dvorak, colemak, any layout)
    var keyboard = if (Keyboard != void) blk: {
        // Try to get X11 connection info for layout query
        const x11_info = win.getX11Info();
        if (x11_info) |info| {
            break :blk Keyboard.initFromX11(info.conn, info.root) catch
                Keyboard.init() catch null;
        } else {
            break :blk Keyboard.init() catch null;
        }
    } else null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var prefix = KeyHandler.PrefixState{};
    var selection = Selection{};
    _ = &selection;
    var mouse_down = false;
    _ = &mouse_down;
    var mouse_start_row: u16 = 0;
    var mouse_start_col: u16 = 0;
    _ = &mouse_start_row;
    _ = &mouse_start_col;
    var pty_buf: [8192]u8 = undefined;
    var running = true;

    // Scrollback browsing state
    var scroll_offset: u32 = 0;
    var saved_cells: ?[]Grid.Cell = null;
    defer if (saved_cells) |sc| allocator.free(sc);

    while (running) {
        // Check prefix timeout
        if (prefix.isExpired()) {
            prefix.reset();
        }

        while (win.pollEvents()) |event| {
            switch (event) {
                .close => running = false,
                .expose => {
                    // Window exposed (uncovered, mapped, scratchpad toggle)
                    // Force full redraw to prevent black fragments
                    for (mux.panes.items) |*pane| pane.grid.dirty = true;
                },
                .resize => |sz| {
                    // Resize renderer
                    renderer.resize(sz.width, sz.height);

                    // Recalculate grid dimensions
                    const new_cols: u16 = @intCast((sz.width -| padding * 2) / atlas.cell_width);
                    const new_rows: u16 = @intCast((sz.height -| padding * 2) / atlas.cell_height);
                    grid_cols = new_cols;
                    grid_rows = new_rows;

                    // Resize all panes in the active workspace
                    // In multi-pane mode, panes share the screen — each gets
                    // a portion. For simplicity, resize all to the max grid
                    // size and let renderAll handle clipping via layout rects.
                    for (mux.panes.items) |*pane| {
                        if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                            pane.resize(allocator, new_rows, new_cols) catch continue;
                        }
                    }

                    // Exit scroll mode on resize — grid dimensions changed,
                    // saved_cells is stale. PTY output will refresh the grid.
                    if (scroll_offset > 0) {
                        scroll_offset = 0;
                        if (saved_cells) |sc| {
                            allocator.free(sc);
                            saved_cells = null;
                        }
                    }
                },
                .key_press => |key| {
                    const XKB_KEY_Page_Up: u32 = 0xff55;
                    const XKB_KEY_Page_Down: u32 = 0xff56;
                    const SHIFT_MASK: u32 = 1; // XCB ShiftMask

                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            // Peek keysym before processKey updates state
                            const keysym = kb.getKeysym(key.keycode);

                            // Shift+PageUp/Down: scrollback browsing
                            if (key.modifiers & SHIFT_MASK != 0) {
                                if (keysym == XKB_KEY_Page_Up) {
                                    const max_offset = if (mux.getActivePane()) |pane|
                                        if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                    else
                                        0;
                                    if (max_offset > 0) {
                                        scroll_offset = @min(scroll_offset + grid_rows, max_offset);
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    // Update xkb state without forwarding to PTY
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                } else if (keysym == XKB_KEY_Page_Down) {
                                    if (scroll_offset > 0) {
                                        scroll_offset -|= grid_rows;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                }
                            }

                            // Any other key while in scroll mode: exit scroll mode
                            if (scroll_offset > 0) {
                                scroll_offset = 0;
                                // Restore saved cells
                                if (saved_cells) |sc| {
                                    if (mux.getActivePane()) |pane| {
                                        if (sc.len == pane.grid.cells.len) {
                                            @memcpy(pane.grid.cells, sc);
                                        }
                                        pane.grid.dirty = true;
                                    }
                                    allocator.free(sc);
                                    saved_cells = null;
                                }
                            }

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
                                    KeyHandler.handleMuxCommand(key_buf[0], &mux, &graph, &hooks, &running, grid_rows, grid_cols, io);
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
                        if (scroll_offset > 0) {
                            scroll_offset = 0;
                            if (saved_cells) |sc| {
                                if (mux.getActivePane()) |pane| {
                                    if (sc.len == pane.grid.cells.len) {
                                        @memcpy(pane.grid.cells, sc);
                                    }
                                    pane.grid.dirty = true;
                                }
                                allocator.free(sc);
                                saved_cells = null;
                            }
                        }
                        if (prefix.awaiting) {
                            prefix.reset();
                            if (key.keycode < 128) {
                                KeyHandler.handleMuxCommand(@truncate(key.keycode), &mux, &graph, &hooks, &running, grid_rows, grid_cols, io);
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
                            // Clear any existing selection on click
                            if (selection.active) {
                                selection.clear();
                                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                            }
                            // Record click position — don't start selection yet.
                            // Selection only begins on mouse_motion (drag).
                            const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                            mouse_start_row = row;
                            mouse_start_col = col;
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
                        const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        selection.update(row, col);

                        // Only finalize selection if mouse actually moved (not a single click)
                        if (selection.start_row != selection.end_row or selection.start_col != selection.end_col) {
                            selection.finish();
                            if (mux.getActivePane()) |pane| {
                                var sel_buf: [8192]u8 = undefined;
                                const len = selection.getText(&pane.grid, &sel_buf);
                                if (len > 0) {
                                    Clipboard.copy(sel_buf[0..len]);
                                }
                            }
                        } else {
                            // Single click: clear selection (already cleared on press)
                            selection.clear();
                        }
                    }
                },
                .mouse_motion => |motion| {
                    if (mouse_down) {
                        const col: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(motion.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        // Start selection on first drag movement
                        if (!selection.active) {
                            selection.begin(mouse_start_row, mouse_start_col);
                        }
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

        // Poll MCP server for incoming connections
        if (mcp) |*m| m.poll();

        // Check for agent protocol events on all panes
        for (mux.panes.items) |*pane| {
            if (pane.vt.consumeAgentEvent()) |payload| {
                if (protocol.parsePayload(payload)) |event_data| {
                    switch (event_data.command) {
                        .start => {
                            const node_id = graph.spawn(.{
                                .name = event_data.name orelse "agent",
                                .kind = .agent,
                                .pid = null,
                                .agent = .{
                                    .group = event_data.group orelse "default",
                                    .role = event_data.role orelse "worker",
                                },
                            }) catch continue;
                            hooks.fire(.agent_start);

                            // Auto-workspace: if group specified, move to/create workspace
                            if (event_data.group) |group_name| {
                                autoAssignAgentWorkspace(&mux, node_id, group_name);
                            }
                        },
                        .stop => {
                            // Find agent node by name and mark finished
                            if (event_data.name) |name| {
                                markAgentFinished(&graph, name, event_data.exit_status);
                            }
                        },
                        .status => {
                            // Update progress/task on the agent node
                            if (event_data.name) |name| {
                                updateAgentStatusByName(&graph, name, event_data.task_desc, event_data.progress);
                            }
                        },
                        .task => {
                            if (event_data.name) |name| {
                                updateAgentStatusByName(&graph, name, event_data.task_desc, null);
                            }
                        },
                        .group => {}, // handled at start
                        .meta => {}, // future use
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
            // Scrollback overlay: temporarily replace grid cells with scrollback text
            if (scroll_offset > 0) {
                if (mux.getActivePane()) |pane| {
                    if (pane.grid.scrollback) |sb| {
                        // Save original cells on first entry
                        if (saved_cells == null) {
                            saved_cells = allocator.dupe(Grid.Cell, pane.grid.cells) catch null;
                        }
                        // Fill grid with scrollback content
                        fillGridWithScrollback(&pane.grid, sb, scroll_offset);
                    }
                }
            }

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
            // 1ms idle sleep via native Io.sleep
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
}

/// Fill the grid with scrollback text for browsing mode.
/// scroll_offset is the number of lines from the bottom of scrollback.
/// The last row shows a "[SCROLL +N]" indicator.
fn fillGridWithScrollback(grid: *Grid, sb: *const Scrollback, scroll_offset: u32) void {
    const rows = grid.rows;
    const cols = grid.cols;

    // Clear entire grid
    for (grid.cells) |*c| c.* = Grid.Cell.blank();

    // Reserve last row for scroll indicator
    const content_rows: u16 = if (rows > 1) rows - 1 else rows;

    // scroll_offset=1 means show the most recent scrollback line at the bottom.
    // We want to show lines [offset - content_rows, offset) from the end,
    // where offset 0 is the most recent line.
    // Line at offset (scroll_offset - 1) is the bottom content line.
    // Line at offset (scroll_offset - 1 + content_rows - 1) is the top content line.

    var row: u16 = 0;
    while (row < content_rows) : (row += 1) {
        // Which scrollback line to show on this grid row?
        // Top row = furthest back, bottom row = most recent in this view
        const lines_from_bottom = scroll_offset -| 1 + (content_rows - 1 - row);
        const text = sb.getLineByOffset(lines_from_bottom) orelse continue;

        // Write text into grid row
        var col: u16 = 0;
        for (text) |byte| {
            if (col >= cols) break;
            grid.cellAt(row, col).char = byte;
            grid.cellAt(row, col).fg = .default;
            col += 1;
        }
    }

    // Draw scroll indicator on the last row
    if (rows > 0) {
        const indicator_row = rows - 1;
        var buf: [64]u8 = undefined;
        const indicator = std.fmt.bufPrint(&buf, "[SCROLL +{d}]", .{scroll_offset}) catch "[SCROLL]";

        var col: u16 = 0;
        for (indicator) |byte| {
            if (col >= cols) break;
            const cell = grid.cellAt(indicator_row, col);
            cell.char = byte;
            cell.fg = .{ .indexed = 208 }; // orange
            cell.attrs.bold = true;
            col += 1;
        }

        // Show total lines available
        const total = sb.lineCount();
        const info = std.fmt.bufPrint(buf[indicator.len..], " ({d} lines)", .{total}) catch "";
        for (info) |byte| {
            if (col >= cols) break;
            const cell = grid.cellAt(indicator_row, col);
            cell.char = byte;
            cell.fg = .{ .indexed = 245 }; // gray
            col += 1;
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

// ── Agent lifecycle helpers ────────────────────────────────────

/// Assign an agent node to a workspace matching its group name.
/// Uses a simple hash of the group name to pick workspace 1-8.
fn autoAssignAgentWorkspace(mux: *Multiplexer, node_id: u64, group: []const u8) void {
    // Hash group name to a workspace index (1-8, workspace 0 is the default shell workspace)
    var hash: u32 = 0;
    for (group) |c| {
        hash = hash *% 31 +% c;
    }
    const ws: u8 = @truncate((hash % 8) + 1);

    // Ensure the pane is in the layout engine's workspace
    const ws_engine = &mux.layout_engine.workspaces[ws];
    ws_engine.addNode(mux.allocator, node_id) catch {
        // Layout tracking failure — agent runs but won't appear in workspace view
        return;
    };

    // Update the graph node's workspace
    if (mux.graph) |g| {
        g.moveToWorkspace(node_id, ws);
    }
}

/// Mark an agent as finished by looking it up by name.
fn markAgentFinished(graph: *ProcessGraph, name: []const u8, exit_status: ?[]const u8) void {
    const node_id = graph.findAgentByName(name) orelse return;
    const exit_code: u8 = if (exit_status) |status| blk: {
        if (std.mem.eql(u8, status, "success") or std.mem.eql(u8, status, "0")) {
            break :blk 0;
        }
        break :blk 1;
    } else 1;
    graph.markFinished(node_id, exit_code);
}

/// Update an agent's task description and progress by name.
fn updateAgentStatusByName(graph: *ProcessGraph, name: []const u8, task: ?[]const u8, progress: ?f32) void {
    const node_id = graph.findAgentByName(name) orelse return;
    graph.updateAgentStatus(node_id, task, progress);
}

fn runRawMode(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
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

    const SA_RESTART = 0x10000000; // linux/signal.h: restart interrupted syscalls
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = SA_RESTART,
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
