//! libteru — AI-first terminal emulator core library.
//!
//! This is the kernel of teru: a C-ABI compatible library containing
//! all platform-independent terminal emulation logic.
//!
//! Modules:
//!   pty      — Pseudoterminal management (spawn, read, write, resize)
//!   graph    — Process graph (DAG of all processes/agents)
//!   agent    — Agent protocol parser (OSC 9999) and MCP bridge
//!   core     — Terminal state, raw mode, I/O loop
//!   tiling   — Layout engine (master-stack, grid, monocle, floating)
//!   config   — Lua configuration loader
//!   persist  — Session serialization and scrollback compression

pub const Pty = @import("pty/Pty.zig");
pub const ProcessGraph = @import("graph/ProcessGraph.zig");
pub const protocol = @import("agent/protocol.zig");
pub const HookHandler = @import("agent/HookHandler.zig");
pub const Terminal = @import("core/Terminal.zig");
pub const Grid = @import("core/Grid.zig");
pub const VtParser = @import("core/VtParser.zig");
pub const Session = @import("persist/Session.zig");
pub const LayoutEngine = @import("tiling/LayoutEngine.zig");
pub const render = @import("render/render.zig");

test {
    _ = Pty;
    _ = ProcessGraph;
    _ = protocol;
    _ = HookHandler;
    _ = Terminal;
    _ = Grid;
    _ = VtParser;
    _ = Session;
    _ = LayoutEngine;
    _ = render;
}
