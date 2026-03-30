# teru -- AI-first terminal emulator

Written in Zig 0.15+. Uses libc.

## Build
zig build          # build
zig build test     # test
zig build run      # run

## Architecture
- src/core/ -- Terminal raw mode, VT parser, character grid
- src/pty/ -- PTY management (Linux: posix_openpt/forkpty)
- src/graph/ -- Process graph (DAG of all processes/agents)
- src/agent/ -- Agent protocol (OSC 9999), Claude Code hook handler
- src/tiling/ -- Layout engine (master-stack, grid, monocle, floating)
- src/persist/ -- Session serialization, binary format
- src/config/ -- Lua config loader (planned)
- src/platform/ -- Platform shells: GTK4/Linux, AppKit/macOS, Win32/Windows (planned)

## Zig 0.15 API Notes
- No std.io.getStdOut() -- use posix.write(STDOUT_FILENO, data)
- callconv(.c) not .C
- winsize fields: .row, .col (no ws_ prefix)
- termios flags: direct bool fields (raw.iflag.ICRNL = false)
- cflag.CSIZE = .CS8 (not cflag.CS8)
- pollfd events/revents are raw i16
- Build: b.createModule() + addExecutable(.{ .root_module = mod })

## Testing
All modules have inline tests. Run with `zig build test`.
