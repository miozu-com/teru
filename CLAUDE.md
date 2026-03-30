# teru -- AI-first terminal emulator

Written in Zig 0.16+. Uses libc.

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
- src/config/ -- Config file parser (key=value format)
- src/compat.zig -- Zig 0.16 compatibility layer (file I/O, time, sleep)
- src/platform/ -- Platform shells: X11+Wayland/Linux, AppKit/macOS, Win32/Windows (planned)

## Zig 0.16 API Notes
- std.io module removed -- no fixedBufferStream, GenericWriter, GenericReader
- std.fs.cwd() removed -- use compat.openFile/createFile (raw POSIX openat)
- std.posix: fork, close, write, open, dup2, pipe2, waitpid, getenv, fcntl, ftruncate all removed
  - fork -> std.os.linux.fork() (returns usize, check with @bitCast)
  - close -> std.posix.system.close() (returns c_int, must assign to _)
  - write -> std.c.write()
  - open -> posix.openatZ(posix.AT.FDCWD, ...)
  - dup2 -> std.c.dup2()
  - pipe2 -> std.c.pipe()
  - waitpid -> std.c.waitpid()
  - getenv -> std.c.getenv() (returns ?[*:0]u8, use std.mem.sliceTo)
  - fcntl -> std.c.fcntl()
  - ftruncate -> std.c.ftruncate()
  - exit -> std.os.linux.exit()
- std.time.nanoTimestamp() removed -> use linux.clock_gettime(.REALTIME, &ts)
- std.Thread.sleep() removed -> use linux.nanosleep()
- std.heap.GeneralPurposeAllocator -> std.heap.DebugAllocator
- std.process.argsAlloc() removed -> accept std.process.Init.Minimal in main()
- ArrayListUnmanaged: default init .{} -> .empty
- PROT.READ|PROT.WRITE -> .{ .READ = true, .WRITE = true } (packed struct)
- Sigaction handler: fn(c_int) -> fn(posix.SIG)
- @Type builtin removed (macOS MsgSendType needs future replacement)
- callconv(.c) not .C
- winsize fields: .row, .col (no ws_ prefix)
- termios flags: direct bool fields (raw.iflag.ICRNL = false)
- cflag.CSIZE = .CS8 (not cflag.CS8)
- pollfd events/revents are raw i16
- Build: b.createModule() + addExecutable(.{ .root_module = mod })

## Testing
All modules have inline tests. Run with `zig build test`.
