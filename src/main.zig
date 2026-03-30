const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Grid = @import("core/Grid.zig");
const VtParser = @import("core/VtParser.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
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
        out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help       Show this help\n  --version    Show version\n  --raw        Raw passthrough mode (no window)\n\n");
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

    var grid = try Grid.init(allocator, grid_rows, grid_cols);
    defer grid.deinit(allocator);

    var vt = VtParser.init(&grid);

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    var keyboard = if (Keyboard != void)
        Keyboard.init() catch null
    else
        null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var pty = try Pty.spawn(.{ .rows = grid_rows, .cols = grid_cols });
    defer pty.deinit();

    _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pty.child_pid });

    // Non-blocking PTY reads
    const flags = try posix.fcntl(pty.master, posix.F.GETFL, 0);
    _ = try posix.fcntl(pty.master, posix.F.SETFL, flags | 0x800);

    var pty_buf: [8192]u8 = undefined;
    var running = true;

    while (running) {
        while (win.pollEvents()) |event| {
            switch (event) {
                .close => running = false,
                .resize => |sz| {
                    renderer.resize(sz.width, sz.height);
                    const new_cols: u16 = @intCast(sz.width / atlas.cell_width);
                    const new_rows: u16 = @intCast(sz.height / atlas.cell_height);
                    if (new_cols != grid.cols or new_rows != grid.rows) {
                        grid.resize(allocator, new_rows, new_cols) catch {
                            continue; // Grid keeps old size; skip PTY resize to avoid mismatch
                        };
                        pty.resize(new_rows, new_cols);
                    }
                },
                .key_press => |key| {
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            var key_buf: [32]u8 = undefined;
                            const len = kb.processKey(key.keycode, true, &key_buf);
                            if (len > 0) {
                                _ = pty.write(key_buf[0..len]) catch {};
                            }
                        }
                    } else {
                        // Fallback: raw keycode passthrough (no xkbcommon)
                        if (key.keycode < 128) {
                            const byte = [1]u8{@truncate(key.keycode)};
                            _ = pty.write(&byte) catch {};
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

        const n = posix.read(pty.master, &pty_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break,
        };
        if (n > 0) {
            vt.feed(pty_buf[0..n]);
            grid.dirty = true;

            // Check for agent protocol events (OSC 9999)
            if (vt.consumeAgentEvent()) |payload| {
                if (protocol.parsePayload(payload)) |event| {
                    // Update process graph with agent metadata
                    switch (event.command) {
                        .start => {
                            _ = graph.spawn(.{
                                .name = event.name orelse "agent",
                                .kind = .agent,
                                .pid = null,
                            }) catch {};
                        },
                        else => {},
                    }
                }
            }
        }

        if (grid.dirty) {
            renderer.render(&grid);
            if (renderer.getFramebuffer()) |fb| {
                const sz = win.getSize();
                win.putFramebuffer(fb, sz.width, sz.height);
            }
            grid.dirty = false;
        } else {
            std.Thread.sleep(1_000_000); // 1ms idle
        }
    }
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
