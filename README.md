# teru 照

AI-first terminal emulator, multiplexer, and tiling manager. Written in Zig.

One binary replaces Alacritty + tmux + terminal management in your window manager.

## Status

**v0.0.1** — PTY spawning, process graph, agent protocol parser. Raw passthrough mode (no GPU rendering yet).

## Build

Requires **Zig 0.16+** (0.16-dev or later).

```bash
# Build and run
zig build run

# Run tests
zig build test
```

## Architecture

```
┌──────────────────────────────────────────────┐
│              Platform Shell                   │
│  GTK4 (Linux) · AppKit (macOS) · Win32 (Win) │
├──────────────────────────────────────────────┤
│              libteru (C ABI)                  │
│                                              │
│  ┌─────────┐ ┌──────────┐ ┌──────────────┐  │
│  │   PTY   │ │ Process  │ │    Agent     │  │
│  │ Manager │ │  Graph   │ │  Protocol    │  │
│  └─────────┘ └──────────┘ └──────────────┘  │
│  ┌─────────┐ ┌──────────┐ ┌──────────────┐  │
│  │ Tiling  │ │ Session  │ │    Config    │  │
│  │ Engine  │ │ Persist  │ │    (Lua)     │  │
│  └─────────┘ └──────────┘ └──────────────┘  │
└──────────────────────────────────────────────┘
```

### Core Concepts

**Process Graph** — Every process (shell, command, AI agent) is a node in a directed acyclic graph. Nodes have parent-child relationships, lifecycle state, and optional agent metadata. The graph is the single source of truth for everything running in the terminal.

**Agent Protocol (OSC 9999)** — Custom escape sequences that let any process self-declare as an AI agent. When Claude Code (or any AI tool) spawns agents, teru understands the team structure, tracks progress, and auto-organizes workspaces.

```bash
# An agent declares itself:
printf '\e]9999;agent:start;name=backend-dev;group=team-temporal\a'
```

**Tiling Engine** — Built-in layouts (master-stack, grid, monocle, floating) with xmonad-style keybindings. Workspaces are auto-created for agent groups. Nodes can be moved between workspaces by dragging or keyboard shortcuts.

**Session Persistence** — Detach/attach like tmux, but with compressed scrollback (LZ4) and crash recovery via write-ahead log. Close your laptop, reopen, everything is back.

## Thread Model

```
Shared:   1 Render + 1 Agent + 1 Persist = 3 threads
Per-node: 1 I/O thread per terminal
Total:    N + 3 threads (not 5N)
```

## Project Structure

```
src/
├── main.zig              # Entry point, CLI, startup
├── lib.zig               # libteru public API
├── core/
│   ├── Terminal.zig      # Raw mode, I/O loop
│   ├── Grid.zig          # Character grid, cells, cursor, scroll regions
│   └── VtParser.zig      # VT100/xterm state machine
├── pty/
│   └── Pty.zig           # PTY spawn, read, write, resize
├── graph/
│   └── ProcessGraph.zig  # Process DAG, node lifecycle
├── agent/
│   ├── protocol.zig      # OSC 9999 parser
│   └── HookHandler.zig   # Claude Code hook JSON parser
├── tiling/
│   └── LayoutEngine.zig  # 4 layouts, 9 workspaces, swap layouts
├── persist/
│   └── Session.zig       # Binary serialization, JSON export
├── config/               # Lua config loader (planned)
└── platform/
    ├── linux/            # GTK4 + OpenGL (planned)
    ├── macos/            # AppKit + Metal (planned)
    └── windows/          # Win32 + ConPTY (v2)
```

## Roadmap

### v0.1 — Foundation
- [x] PTY management (spawn, read, write, resize, SIGWINCH)
- [x] Process graph (DAG, node lifecycle, agent queries)
- [x] Agent protocol parser (OSC 9999)
- [x] Raw terminal passthrough mode
- [x] VT state machine (CSI, SGR, erase, scroll, alt screen, OSC)
- [x] Character grid (Unicode cells, colors, attributes, scroll regions)
- [x] Tiling engine (master-stack, grid, monocle, floating)
- [x] Session persistence (binary serialization, JSON export)
- [x] Claude Code hook handler (5 event types)
- [ ] Multiplexing (multiple PTYs, split view)

### v0.2 — Rendering
- [ ] GPU rendering (OpenGL on Linux, Metal on macOS)
- [ ] Font rendering (FreeType + HarfBuzz)
- [ ] GTK4 platform shell (Linux)
- [ ] Kitty keyboard protocol
- [ ] Kitty graphics protocol

### v0.3 — AI Integration
- [ ] MCP server (Unix socket)
- [ ] Auto-workspace for agent groups
- [ ] Agent status in tab bar

### v0.4 — Persistence
- [ ] Detach/attach (daemon mode)
- [ ] LZ4 compressed scrollback
- [ ] Session serialization
- [ ] Crash recovery (WAL)

### v0.5 — Configuration
- [ ] Lua config (Ziglua)
- [ ] Hot reload
- [ ] Themes
- [ ] Keybinding customization

### v1.0 — Release
- [ ] WASM plugin system
- [ ] macOS platform shell
- [ ] Terminfo entry
- [ ] Shell integration (semantic blocks)

## Design Principles

1. **Process graph, not pane grid** — the terminal understands process relationships, not just rectangular regions
2. **AI-native** — agent orchestration is a first-class concept, not a bolt-on
3. **Zero-config works** — compiled-in defaults for everything, config file is optional
4. **Memory-efficient** — compressed scrollback, shared threads, no buffer duplication
5. **Library-first** — libteru is a C-ABI library that any platform shell can embed

## Acknowledgments

Architectural inspiration from [Ghostty](https://ghostty.org) (Zig terminal, libghostty pattern, paged memory), [Zellij](https://zellij.dev) (WASM plugins, swap layouts), and [Warp](https://warp.dev) (semantic blocks, AI integration).

## License

MIT
