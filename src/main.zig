const std = @import("std");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Grid = @import("core/Grid.zig");
const VtParser = @import("core/VtParser.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");

const version = "0.0.2";

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

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        var buf: [64]u8 = undefined;
        outFmt(&buf, "teru {s}\n", .{version});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        out("teru — AI-first terminal emulator\n" ++
            "\n" ++
            "Usage: teru [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --help       Show this help\n" ++
            "  --version    Show version\n" ++
            "  --raw        Raw passthrough mode (no GPU window)\n" ++
            "\n");
        return;
    }

    // Raw passthrough mode (original behavior, no window)
    if (args.len > 1 and std.mem.eql(u8, args[1], "--raw")) {
        return runRawMode(allocator);
    }

    // Default: windowed GPU mode
    return runWindowedMode(allocator);
}

// ── Windowed GPU mode ────────────────────────────────────────────

fn runWindowedMode(allocator: std.mem.Allocator) !void {
    // Initialize process graph
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    // Create platform window (auto-detects X11 vs Wayland)
    var win = try platform.Platform.init(960, 640, "teru");
    defer win.deinit();

    // Initialize font atlas
    var atlas = try render.FontAtlas.init(allocator, null, 16);
    defer atlas.deinit();

    // Initialize OpenGL renderer
    var renderer = try render.Renderer.init(
        allocator,
        960,
        640,
        &getProcAddr,
    );
    defer renderer.deinit();

    // Upload font atlas texture
    renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);

    // Calculate grid dimensions from window size and cell size
    const grid_cols: u16 = @intCast(960 / atlas.cell_width);
    const grid_rows: u16 = @intCast(640 / atlas.cell_height);

    // Initialize character grid
    var grid = try Grid.init(allocator, grid_rows, grid_cols);
    defer grid.deinit(allocator);

    // Initialize VT parser
    var vt = VtParser.init(&grid);

    // Spawn PTY with shell
    var pty = try Pty.spawn(.{
        .rows = grid_rows,
        .cols = grid_cols,
    });
    defer pty.deinit();

    // Register in process graph
    _ = try graph.spawn(.{
        .name = "shell",
        .kind = .shell,
        .pid = pty.child_pid,
    });

    // Make PTY master non-blocking for the event loop
    const flags = try posix.fcntl(pty.master, posix.F.GETFL, 0);
    _ = try posix.fcntl(pty.master, posix.F.SETFL, flags | 0x800); // O_NONBLOCK = 0x800

    // Main event loop
    var pty_buf: [8192]u8 = undefined;
    var running = true;

    while (running) {
        // 1. Poll platform events (window close, resize, keyboard)
        while (win.pollEvents()) |event| {
            switch (event) {
                .close => running = false,
                .resize => |sz| {
                    renderer.resize(sz.width, sz.height);
                    const new_cols: u16 = @intCast(sz.width / atlas.cell_width);
                    const new_rows: u16 = @intCast(sz.height / atlas.cell_height);
                    if (new_cols != grid.cols or new_rows != grid.rows) {
                        grid.resize(allocator, new_rows, new_cols) catch {};
                        pty.resize(new_rows, new_cols);
                    }
                },
                .key_press => |key| {
                    // TODO: proper keycode → UTF-8 translation via xkbcommon
                    // For now, pass raw keycodes for basic ASCII
                    if (key.keycode >= 0 and key.keycode < 128) {
                        const byte = [1]u8{@truncate(key.keycode)};
                        _ = pty.write(&byte) catch {};
                    }
                },
                else => {},
            }
        }

        // 2. Read PTY output (non-blocking)
        const n = posix.read(pty.master, &pty_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break,
        };
        if (n > 0) {
            // Feed through VT parser → updates grid
            vt.feed(pty_buf[0..n]);
            grid.dirty = true;
        }

        // 3. Render if dirty
        if (grid.dirty) {
            renderer.render(&grid);
            win.swapBuffers();
            grid.dirty = false;
        } else {
            // Sleep briefly to avoid busy-waiting when idle
            std.Thread.sleep(1_000_000); // 1ms
        }
    }
}

// ── Raw passthrough mode (no window, runs in host terminal) ──────

fn runRawMode(allocator: std.mem.Allocator) !void {
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var terminal = Terminal.init();
    defer terminal.deinit();

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty = try Pty.spawn(.{
        .rows = size.rows,
        .cols = size.cols,
    });
    defer pty.deinit();

    const node_id = try graph.spawn(.{
        .name = "shell",
        .kind = .shell,
        .pid = pty.child_pid,
    });

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0x10000000, // SA_RESTART
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
        const exit_code: u8 = @truncate(status >> 8);
        graph.markFinished(node_id, exit_code);
    }

    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s) in graph\n", .{graph.nodeCount()});
}

// ── GL proc address wrapper ──────────────────────────────────────

fn getProcAddr(name: [*:0]const u8) ?*const anyopaque {
    return platform.Platform.getProcAddressStatic(name);
}

// ── Signal handling ──────────────────────────────────────────────

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

fn handleSigwinch(_: c_int) callconv(.c) void {
    if (g_pty_master_fd < 0) return;
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return;
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}
