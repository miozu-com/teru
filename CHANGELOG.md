# Changelog

## 0.0.1 (2026-03-30)

Initial release. Foundation architecture — no GPU rendering yet.

### What works
- PTY spawning and management (Linux, posix_openpt/forkpty)
- Process graph — DAG of all processes/agents with lifecycle tracking
- VT state machine — cursor movement, SGR colors (256 + truecolor), erase, scroll, alt screen
- Character grid — Unicode cells with attributes, scroll regions, resize
- Tiling engine — master-stack, grid, monocle, floating layouts across 9 workspaces
- Session persistence — binary serialization/deserialization, JSON export
- Agent protocol — OSC 9999 escape sequence parser for AI agent self-declaration
- Claude Code hook handler — parses SubagentStart/Stop, TaskCreated/Completed, TeammateIdle
- Raw terminal passthrough mode — your shell runs inside teru's PTY

### Not yet implemented
- GPU rendering (OpenGL/Metal)
- Font rendering (FreeType + HarfBuzz)
- Multiplexing (split panes)
- Detach/attach (daemon mode)
- Lua configuration
- WASM plugins
- macOS/Windows support
