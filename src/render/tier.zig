//! Rendering tier auto-detection and unified renderer dispatch.
//!
//! Three-tier architecture:
//!   GPU  — OpenGL 4.6 + X11/Wayland EGL (desktop with GPU)
//!   CPU  — SIMD software raster + X11 SHM (desktop without GPU, VM, old laptop)
//!   TTY  — VT output to host terminal (SSH, server, container, --raw mode)
//!
//! The detector probes the environment at startup (display server presence,
//! DRI render nodes) and returns the best available tier. The caller then
//! initializes only the matching renderer.

const std = @import("std");
const Grid = @import("../core/Grid.zig");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;

// ── Tier detection ─────────────────────────────────────────────────

pub const RenderTier = enum {
    gpu, // OpenGL 4.6 available
    cpu, // X11/Wayland but no GPU (or GPU init failed)
    tty, // No display server (SSH, pure console)

    pub fn label(self: RenderTier) []const u8 {
        return switch (self) {
            .gpu => "gpu (OpenGL 4.6)",
            .cpu => "cpu (SIMD software)",
            .tty => "tty (VT escape codes)",
        };
    }
};

/// Detect the best rendering tier for the current environment.
/// Checks display server availability and GPU device nodes.
pub fn detectTier() RenderTier {
    // 1. Check for a display server (X11 or Wayland)
    const has_display = hasDisplayServer();
    if (!has_display) return .tty;

    // 2. Try to detect GPU availability via DRI render nodes
    if (canAccessGpu()) return .gpu;

    // 3. Display server exists but no GPU — CPU software rendering
    return .cpu;
}

/// Check if a display server is running (X11 or Wayland).
fn hasDisplayServer() bool {
    const display = std.posix.getenv("DISPLAY");
    if (display != null) return true;

    const wayland = std.posix.getenv("WAYLAND_DISPLAY");
    if (wayland != null) return true;

    return false;
}

/// Check if GPU hardware is accessible via DRI device nodes.
/// Probes /dev/dri/renderD128 (preferred) and /dev/dri/card0 (fallback).
fn canAccessGpu() bool {
    // Primary: DRM render node (present on modern Mesa/NVIDIA drivers)
    if (accessPath("/dev/dri/renderD128")) return true;

    // Fallback: DRI card node (older setups, may require group membership)
    if (accessPath("/dev/dri/card0")) return true;

    return false;
}

/// Check if a filesystem path is accessible (exists and readable).
fn accessPath(path: [*:0]const u8) bool {
    const rc = std.c.access(path, 0); // F_OK = 0
    return rc == 0;
}

// ── Unified renderer dispatch ──────────────────────────────────────

/// Tagged union that dispatches to the active rendering tier.
/// GPU and CPU tiers produce pixel framebuffers; TTY mode writes
/// VT escape sequences (no pixel renderer needed).
pub const Renderer = union(enum) {
    gpu: GpuHandle,
    cpu: SoftwareRenderer,
    tty: void, // TTY mode doesn't use a pixel renderer

    /// Opaque handle for the GPU renderer. Defined here rather than
    /// importing opengl.zig directly, because opengl.zig requires
    /// GPU libraries that may not be linked (e.g., in test builds
    /// or TTY-only builds). The platform layer creates the concrete
    /// GPU renderer and passes it as this handle.
    pub const GpuHandle = struct {
        /// Pointer to the actual opengl.Renderer, type-erased.
        ptr: *anyopaque,
        render_fn: *const fn (*anyopaque, *const Grid) void,
        resize_fn: *const fn (*anyopaque, u32, u32) void,
        update_atlas_fn: *const fn (*anyopaque, []const u8, u32, u32) void,
        deinit_fn: *const fn (*anyopaque) void,
    };

    /// Render the grid using whichever tier is active.
    pub fn render(self: *Renderer, grid: *const Grid) void {
        switch (self.*) {
            .gpu => |gpu| gpu.render_fn(gpu.ptr, grid),
            .cpu => |*cpu| cpu.render(grid),
            .tty => {}, // TTY rendering is handled separately via VT output
        }
    }

    /// Notify the renderer that the window has been resized.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        switch (self.*) {
            .gpu => |gpu| gpu.resize_fn(gpu.ptr, width, height),
            .cpu => |*cpu| cpu.resize(width, height) catch {},
            .tty => {}, // TTY responds to SIGWINCH, not pixel resize
        }
    }

    /// Upload a new font atlas texture.
    pub fn updateAtlas(self: *Renderer, atlas_data: []const u8, atlas_width: u32, atlas_height: u32) void {
        switch (self.*) {
            .gpu => |gpu| gpu.update_atlas_fn(gpu.ptr, atlas_data, atlas_width, atlas_height),
            .cpu => |*cpu| cpu.updateAtlas(atlas_data, atlas_width, atlas_height),
            .tty => {}, // TTY mode doesn't use an atlas
        }
    }

    /// Clean up the active renderer.
    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            .gpu => |gpu| gpu.deinit_fn(gpu.ptr),
            .cpu => |*cpu| cpu.deinit(),
            .tty => {},
        }
    }

    /// Initialize a CPU-tier renderer.
    pub fn initCpu(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        cell_width: u32,
        cell_height: u32,
    ) !Renderer {
        return .{ .cpu = try SoftwareRenderer.init(allocator, width, height, cell_width, cell_height) };
    }

    /// Initialize a TTY-tier renderer (no-op pixel renderer).
    pub fn initTty() Renderer {
        return .{ .tty = {} };
    }

    /// Get the framebuffer for display (CPU tier only).
    /// Returns null for GPU and TTY tiers.
    pub fn getFramebuffer(self: *const Renderer) ?[]const u32 {
        return switch (self.*) {
            .cpu => |cpu| cpu.getFramebuffer(),
            else => null,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "detectTier returns a valid tier" {
    // Just verify it doesn't crash — the result depends on the host.
    const tier = detectTier();
    _ = tier.label();
}

test "RenderTier labels are distinct" {
    const gpu_label = RenderTier.gpu.label();
    const cpu_label = RenderTier.cpu.label();
    const tty_label = RenderTier.tty.label();

    try std.testing.expect(!std.mem.eql(u8, gpu_label, cpu_label));
    try std.testing.expect(!std.mem.eql(u8, cpu_label, tty_label));
    try std.testing.expect(!std.mem.eql(u8, gpu_label, tty_label));
}

test "Renderer CPU tier init and render" {
    const allocator = std.testing.allocator;

    var grid = try Grid.init(allocator, 2, 3);
    defer grid.deinit(allocator);

    var renderer = try Renderer.initCpu(allocator, 24, 32, 8, 16);
    defer renderer.deinit();

    renderer.render(&grid);

    // Should produce a valid framebuffer
    const fb = renderer.getFramebuffer();
    try std.testing.expect(fb != null);
    try std.testing.expectEqual(@as(usize, 24 * 32), fb.?.len);
}

test "Renderer TTY tier is a no-op" {
    const allocator = std.testing.allocator;

    var grid = try Grid.init(allocator, 2, 3);
    defer grid.deinit(allocator);

    var renderer = Renderer.initTty();
    defer renderer.deinit();

    // These should all be no-ops without crashing
    renderer.render(&grid);
    renderer.resize(100, 50);
    renderer.updateAtlas(&.{}, 0, 0);

    // TTY has no framebuffer
    try std.testing.expectEqual(@as(?[]const u32, null), renderer.getFramebuffer());
}

test "accessPath returns false for nonexistent path" {
    try std.testing.expect(!accessPath("/nonexistent/path/12345"));
}
