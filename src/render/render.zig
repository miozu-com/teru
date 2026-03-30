//! Rendering subsystem for teru.
//!
//! Three-tier rendering architecture:
//!   GPU  — OpenGL 4.6 + X11/Wayland EGL (desktop with GPU)
//!   CPU  — SIMD software raster + X11 SHM (desktop without GPU, VM, old laptop)
//!   TTY  — VT output to host terminal (SSH, server, container, --raw mode)
//!
//! The tier detector probes the environment at startup and selects
//! the best available renderer. Platform shells import this module
//! to set up rendering of the terminal character grid.

pub const opengl = @import("opengl.zig");
pub const GpuRenderer = opengl.Renderer;
pub const CellVertex = opengl.CellVertex;
pub const FontAtlas = @import("FontAtlas.zig");
pub const GlyphInfo = FontAtlas.GlyphInfo;

pub const software = @import("software.zig");
pub const SoftwareRenderer = software.SoftwareRenderer;

pub const tier = @import("tier.zig");
pub const RenderTier = tier.RenderTier;
pub const detectTier = tier.detectTier;
pub const Renderer = tier.Renderer;

test {
    _ = opengl;
    _ = FontAtlas;
    _ = software;
    _ = tier;
}
