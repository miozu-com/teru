const std = @import("std");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Terminal = @import("core/Terminal.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");

const version = "0.0.1";

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
            "\n" ++
            "Keybindings (v0.0.1 — raw passthrough mode):\n" ++
            "  All input is forwarded directly to the shell.\n" ++
            "  Exit with Ctrl+D or type 'exit'.\n" ++
            "\n");
        return;
    }

    // Initialize process graph
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    // Initialize host terminal
    var terminal = Terminal.init();
    defer terminal.deinit();

    // Get host terminal size
    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    // Print startup banner (before raw mode)
    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    // Spawn PTY with user's shell
    var pty = try Pty.spawn(.{
        .rows = size.rows,
        .cols = size.cols,
    });
    defer pty.deinit();

    // Register in process graph
    const node_id = try graph.spawn(.{
        .name = "shell",
        .kind = .shell,
        .pid = pty.child_pid,
    });

    // Set up SIGWINCH handler for terminal resize
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0x10000000, // SA_RESTART
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    // Store PTY master fd for signal handler
    g_pty_master_fd = pty.master;
    g_host_fd = terminal.host_fd;

    // Enter raw mode
    try terminal.enterRawMode();

    // Clear screen and position cursor at top
    out("\x1b[2J\x1b[H");

    // Run I/O loop (blocks until shell exits)
    terminal.runLoop(&pty) catch {};

    // Restore terminal
    terminal.exitRawMode();

    // Mark process as finished in graph
    if (pty.child_pid != null) {
        const status = pty.waitForExit() catch 0;
        const exit_code: u8 = @truncate(status >> 8);
        graph.markFinished(node_id, exit_code);
    }

    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s) in graph\n", .{graph.nodeCount()});
}

// ── Signal handling ──────────────────────────────────────────────

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

fn handleSigwinch(_: c_int) callconv(.c) void {
    if (g_pty_master_fd < 0) return;

    // Read new size from host terminal
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return;

    // Forward to PTY
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}
