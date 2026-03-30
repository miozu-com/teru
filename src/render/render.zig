//! Rendering subsystem for teru.
//!
//! Re-exports the OpenGL renderer and font atlas builder.
//! Platform shells import this module to set up GPU-accelerated
//! rendering of the terminal character grid.

pub const opengl = @import("opengl.zig");
pub const Renderer = opengl.Renderer;
pub const CellVertex = opengl.CellVertex;
pub const FontAtlas = @import("FontAtlas.zig");
pub const GlyphInfo = FontAtlas.GlyphInfo;

test {
    _ = opengl;
    _ = FontAtlas;
}
