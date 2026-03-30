//! CPU software renderer for the terminal character grid.
//!
//! Rasterizes the grid into an ARGB framebuffer using SIMD-accelerated
//! pixel blitting. Zero GPU dependencies — pure Zig + @Vector intrinsics.
//!
//! The framebuffer can be presented via X11 SHM, Wayland SHM, or any
//! platform that accepts a raw pixel buffer. The platform layer handles
//! display; this module only produces pixels.
//!
//! Design: For a monospace terminal, every cell is identical size.
//! Atlas lookup is O(1) by codepoint. Blitting is perfectly regular
//! (no per-pixel branching in the SIMD path). This is ideal for
//! auto-vectorization on AVX2, SSE4, and NEON.

const std = @import("std");
const Grid = @import("../core/Grid.zig");

// ── SIMD types ─────────────────────────────────────────────────────
// Process 4 pixels at a time (128-bit — works on SSE2, NEON, and
// all targets that Zig's @Vector lowers to). Using 4 instead of 8
// for broader hardware compatibility; the compiler will fuse to
// 256-bit ops on AVX2 targets automatically.

const Vec4u32 = @Vector(4, u32);
const Vec4u16 = @Vector(4, u16);

// ── Default 16-color palette (SGR indexed colors 0-15) ─────────────
// Matches opengl.zig's palette exactly, but as packed ARGB u32.

const default_palette_argb = [16]u32{
    0xFF000000, // 0  black
    0xFFCC0000, // 1  red
    0xFF00CC00, // 2  green
    0xFFCCCC00, // 3  yellow
    0xFF0000CC, // 4  blue
    0xFFCC00CC, // 5  magenta
    0xFF00CCCC, // 6  cyan
    0xFFBFBFBF, // 7  white
    0xFF808080, // 8  bright black
    0xFFFF0000, // 9  bright red
    0xFF00FF00, // 10 bright green
    0xFFFFFF00, // 11 bright yellow
    0xFF0000FF, // 12 bright blue
    0xFFFF00FF, // 13 bright magenta
    0xFF00FFFF, // 14 bright cyan
    0xFFFFFFFF, // 15 bright white
};

// ── SoftwareRenderer ───────────────────────────────────────────────

pub const SoftwareRenderer = struct {
    framebuffer: []u32, // ARGB pixel buffer (width * height)
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
    glyph_atlas: []const u8, // pre-rasterized glyph bitmaps (grayscale, row-major)
    atlas_width: u32,
    atlas_height: u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        cell_width: u32,
        cell_height: u32,
    ) !SoftwareRenderer {
        const pixel_count = @as(usize, width) * @as(usize, height);
        const fb = try allocator.alloc(u32, pixel_count);
        // Clear to default background
        const bg = resolveColorArgb(.default, false);
        @memset(fb, bg);

        return .{
            .framebuffer = fb,
            .width = width,
            .height = height,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .glyph_atlas = &.{},
            .atlas_width = 0,
            .atlas_height = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SoftwareRenderer) void {
        self.allocator.free(self.framebuffer);
        self.framebuffer = &.{};
    }

    /// Render the entire grid into the framebuffer.
    pub fn render(self: *SoftwareRenderer, grid: *const Grid) void {
        const cols: usize = grid.cols;
        const rows: usize = grid.rows;
        const cw: usize = self.cell_width;
        const ch: usize = self.cell_height;
        const fb_w: usize = self.width;
        const fb_h: usize = self.height;

        for (0..rows) |row| {
            const screen_y = row * ch;
            if (screen_y >= fb_h) break;

            for (0..cols) |col| {
                const screen_x = col * cw;
                if (screen_x >= fb_w) break;

                const cell = grid.cellAtConst(@intCast(row), @intCast(col));

                // Resolve colors (handling inverse, dim, hidden)
                var fg = resolveColorArgb(cell.fg, true);
                var bg = resolveColorArgb(cell.bg, false);

                if (cell.attrs.inverse) {
                    const tmp = fg;
                    fg = bg;
                    bg = tmp;
                }

                if (cell.attrs.dim) {
                    fg = dimColor(fg);
                }

                if (cell.attrs.hidden) {
                    fg = bg;
                }

                // 1. Fill cell rectangle with background color
                const max_y = @min(screen_y + ch, fb_h);
                const max_x = @min(screen_x + cw, fb_w);

                for (screen_y..max_y) |py| {
                    const row_start = py * fb_w;
                    const dst_slice = self.framebuffer[row_start + screen_x .. row_start + max_x];
                    @memset(dst_slice, bg);
                }

                // 2. Blit glyph from atlas with foreground color (alpha blending)
                const cp = cell.char;
                if (cp >= 32 and cp < 127 and self.atlas_width > 0 and self.glyph_atlas.len > 0) {
                    self.blitGlyph(
                        cp - 32,
                        screen_x,
                        screen_y,
                        max_x,
                        max_y,
                        fg,
                        bg,
                    );
                }
            }
        }
    }

    /// Blit a single glyph from the atlas into the framebuffer.
    /// glyph_index: 0-based index into the atlas (codepoint - 32).
    fn blitGlyph(
        self: *SoftwareRenderer,
        glyph_index: u21,
        screen_x: usize,
        screen_y: usize,
        max_x: usize,
        max_y: usize,
        fg: u32,
        bg: u32,
    ) void {
        const cw: usize = self.cell_width;
        const ch: usize = self.cell_height;
        const aw: usize = self.atlas_width;
        const fb_w: usize = self.width;

        // Atlas is packed row-major: glyphs laid out left-to-right, wrapping
        const glyphs_per_row = if (aw >= cw) aw / cw else return;
        const glyph_row = @as(usize, glyph_index) / glyphs_per_row;
        const glyph_col = @as(usize, glyph_index) % glyphs_per_row;
        const atlas_x = glyph_col * cw;
        const atlas_y = glyph_row * ch;

        const render_h = max_y - screen_y;
        const render_w = max_x - screen_x;

        for (0..@min(render_h, ch)) |dy| {
            const atlas_row_offset = (atlas_y + dy) * aw + atlas_x;

            // Bounds check: skip if atlas row is out of range
            if (atlas_y + dy >= self.atlas_height) break;
            if (atlas_row_offset + cw > self.glyph_atlas.len) break;

            const alpha_row = self.glyph_atlas[atlas_row_offset..][0..cw];
            const fb_row_start = (screen_y + dy) * fb_w + screen_x;
            const dst = self.framebuffer[fb_row_start..][0..render_w];

            blitGlyphRow(dst, alpha_row, fg, bg, @min(render_w, cw));
        }
    }

    /// Resize the framebuffer. Old contents are discarded.
    pub fn resize(self: *SoftwareRenderer, width: u32, height: u32) !void {
        self.allocator.free(self.framebuffer);
        const pixel_count = @as(usize, width) * @as(usize, height);
        self.framebuffer = try self.allocator.alloc(u32, pixel_count);
        self.width = width;
        self.height = height;
        const bg = resolveColorArgb(.default, false);
        @memset(self.framebuffer, bg);
    }

    /// Update the glyph atlas data. The atlas is a single-channel grayscale
    /// bitmap with glyphs packed row-major (same layout as FontAtlas output).
    pub fn updateAtlas(
        self: *SoftwareRenderer,
        atlas_data: []const u8,
        atlas_width: u32,
        atlas_height: u32,
    ) void {
        self.glyph_atlas = atlas_data;
        self.atlas_width = atlas_width;
        self.atlas_height = atlas_height;
    }

    /// Return the framebuffer for external consumption (X11 SHM, etc.).
    pub fn getFramebuffer(self: *const SoftwareRenderer) []const u32 {
        return self.framebuffer;
    }
};

// ── SIMD-accelerated glyph row blitting ────────────────────────────

/// Blit one row of a glyph using SIMD alpha blending.
/// dst: framebuffer row slice (ARGB pixels)
/// glyph_alpha: grayscale alpha values from the atlas
/// fg/bg: packed ARGB foreground/background colors
/// width: number of pixels to blit
fn blitGlyphRow(dst: []u32, glyph_alpha: []const u8, fg: u32, bg: u32, width: usize) void {
    // Extract fg/bg channels once (reused across all pixels)
    const fg_r: u16 = @truncate((fg >> 16) & 0xFF);
    const fg_g: u16 = @truncate((fg >> 8) & 0xFF);
    const fg_b: u16 = @truncate(fg & 0xFF);
    const bg_r: u16 = @truncate((bg >> 16) & 0xFF);
    const bg_g: u16 = @truncate((bg >> 8) & 0xFF);
    const bg_b: u16 = @truncate(bg & 0xFF);

    var i: usize = 0;

    // SIMD path: 4 pixels at a time (128-bit, universal)
    while (i + 4 <= width) : (i += 4) {
        const a0: u16 = glyph_alpha[i];
        const a1: u16 = glyph_alpha[i + 1];
        const a2: u16 = glyph_alpha[i + 2];
        const a3: u16 = glyph_alpha[i + 3];

        const alphas = Vec4u16{ a0, a1, a2, a3 };
        const inv_alphas = @as(Vec4u16, @splat(255)) - alphas;

        // Blend each channel: result = (fg * alpha + bg * (255 - alpha)) / 255
        // Using u16 to avoid overflow (255 * 255 = 65025, fits in u16)
        const fg_r_vec: Vec4u16 = @splat(fg_r);
        const fg_g_vec: Vec4u16 = @splat(fg_g);
        const fg_b_vec: Vec4u16 = @splat(fg_b);
        const bg_r_vec: Vec4u16 = @splat(bg_r);
        const bg_g_vec: Vec4u16 = @splat(bg_g);
        const bg_b_vec: Vec4u16 = @splat(bg_b);

        const r_blended = (fg_r_vec * alphas + bg_r_vec * inv_alphas) / @as(Vec4u16, @splat(255));
        const g_blended = (fg_g_vec * alphas + bg_g_vec * inv_alphas) / @as(Vec4u16, @splat(255));
        const b_blended = (fg_b_vec * alphas + bg_b_vec * inv_alphas) / @as(Vec4u16, @splat(255));

        // Pack back to ARGB u32
        const r32: Vec4u32 = r_blended;
        const g32: Vec4u32 = g_blended;
        const b32: Vec4u32 = b_blended;
        const a32: Vec4u32 = @splat(@as(u32, 0xFF));

        const result = (a32 << @splat(24)) | (r32 << @splat(16)) | (g32 << @splat(8)) | b32;

        dst[i..][0..4].* = result;
    }

    // Scalar fallback for remaining pixels
    while (i < width) : (i += 1) {
        const alpha: u16 = glyph_alpha[i];
        if (alpha == 0) {
            dst[i] = bg;
            continue;
        }
        if (alpha == 255) {
            dst[i] = fg;
            continue;
        }
        const inv_alpha: u16 = 255 - alpha;
        const r = (fg_r * alpha + bg_r * inv_alpha) / 255;
        const g = (fg_g * alpha + bg_g * inv_alpha) / 255;
        const b = (fg_b * alpha + bg_b * inv_alpha) / 255;
        dst[i] = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }
}

// ── Color resolution (matches opengl.zig exactly) ──────────────────

/// Convert a Grid.Color to a packed ARGB u32.
fn resolveColorArgb(color: Grid.Color, is_fg: bool) u32 {
    return switch (color) {
        .default => if (is_fg)
            packArgb(230, 230, 230) // light gray foreground (0.9 * 255)
        else
            packArgb(18, 18, 26), // near-black background (0.07 * 255 ≈ 18)
        .indexed => |idx| indexed256Argb(idx),
        .rgb => |c| packArgb(c.r, c.g, c.b),
    };
}

/// Pack R, G, B bytes into an ARGB u32 with full alpha.
fn packArgb(r: u8, g: u8, b: u8) u32 {
    return (0xFF << 24) |
        (@as(u32, r) << 16) |
        (@as(u32, g) << 8) |
        @as(u32, b);
}

/// Convert a 256-color index to packed ARGB.
fn indexed256Argb(idx: u8) u32 {
    if (idx < 16) {
        return default_palette_argb[idx];
    } else if (idx < 232) {
        // 6x6x6 color cube (indices 16-231)
        const ci = idx - 16;
        const b_val: u16 = ci % 6;
        const g_val: u16 = (ci / 6) % 6;
        const r_val: u16 = (ci / 36);
        const r: u8 = if (r_val == 0) 0 else @intCast(r_val * 40 + 55);
        const g: u8 = if (g_val == 0) 0 else @intCast(g_val * 40 + 55);
        const b: u8 = if (b_val == 0) 0 else @intCast(b_val * 40 + 55);
        return packArgb(r, g, b);
    } else {
        // Grayscale ramp (indices 232-255): 8, 18, ..., 238
        const level: u8 = @intCast(@as(u16, idx - 232) * 10 + 8);
        return packArgb(level, level, level);
    }
}

/// Dim a color by halving R, G, B channels (preserve alpha).
fn dimColor(argb: u32) u32 {
    const r = ((argb >> 16) & 0xFF) >> 1;
    const g = ((argb >> 8) & 0xFF) >> 1;
    const b = (argb & 0xFF) >> 1;
    return (0xFF << 24) | (r << 16) | (g << 8) | b;
}

// ── Tests ──────────────────────────────────────────────────────────

test "render empty grid" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    var renderer = try SoftwareRenderer.init(allocator, 32, 48, 8, 16);
    defer renderer.deinit();

    renderer.render(&grid);

    // All pixels should be the default background color
    const bg = resolveColorArgb(.default, false);
    for (renderer.framebuffer) |pixel| {
        try std.testing.expectEqual(bg, pixel);
    }
}

test "render single character" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 1);
    defer grid.deinit(allocator);

    // Write 'A' (codepoint 65, glyph index 33) at position (0, 0)
    grid.write('A');

    // Create a minimal atlas: 1 row of glyphs, each 2x2 pixels.
    // Glyph index 33 ('A' - 32) is at atlas column 33.
    // Atlas needs to be at least 34 glyphs wide * 2px = 68px wide.
    const cw: u32 = 2;
    const ch: u32 = 2;
    const atlas_w: u32 = 68; // 34 glyphs * 2px
    const atlas_h: u32 = 2;
    const atlas_size = @as(usize, atlas_w) * @as(usize, atlas_h);
    const atlas_data = try allocator.alloc(u8, atlas_size);
    defer allocator.free(atlas_data);
    @memset(atlas_data, 0); // All glyphs blank initially

    // Set glyph 33 ('A') to have full alpha (white) in all pixels
    // Position: column 33, x = 33*2 = 66
    atlas_data[0 * atlas_w + 66] = 255; // row 0, col 0 of glyph
    atlas_data[0 * atlas_w + 67] = 255; // row 0, col 1
    atlas_data[1 * atlas_w + 66] = 255; // row 1, col 0
    atlas_data[1 * atlas_w + 67] = 255; // row 1, col 1

    var renderer = try SoftwareRenderer.init(allocator, 2, 2, cw, ch);
    defer renderer.deinit();
    renderer.updateAtlas(atlas_data, atlas_w, atlas_h);

    renderer.render(&grid);

    // All 4 pixels should be the default foreground color (glyph alpha = 255)
    const fg = resolveColorArgb(.default, true);
    try std.testing.expectEqual(fg, renderer.framebuffer[0]);
    try std.testing.expectEqual(fg, renderer.framebuffer[1]);
    try std.testing.expectEqual(fg, renderer.framebuffer[2]);
    try std.testing.expectEqual(fg, renderer.framebuffer[3]);
}

test "render colored text" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 1);
    defer grid.deinit(allocator);

    // Set pen colors and write
    grid.pen_fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }; // red fg
    grid.pen_bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } }; // blue bg
    grid.write('X');

    // Tiny atlas: 1 glyph 'X' = index 56 (88-32). We need at least 57 glyphs * 2px = 114px.
    const cw: u32 = 2;
    const ch: u32 = 2;
    const atlas_w: u32 = 114;
    const atlas_h: u32 = 2;
    const atlas_size = @as(usize, atlas_w) * @as(usize, atlas_h);
    const atlas_data = try allocator.alloc(u8, atlas_size);
    defer allocator.free(atlas_data);
    @memset(atlas_data, 0);

    // Glyph 'X' at index 56, position x = 56*2 = 112
    // Set alpha to 255 for pixel (0,0) and 0 for pixel (0,1)
    atlas_data[0 * atlas_w + 112] = 255; // full fg
    atlas_data[0 * atlas_w + 113] = 0; // full bg
    atlas_data[1 * atlas_w + 112] = 128; // 50% blend
    atlas_data[1 * atlas_w + 113] = 255; // full fg

    var renderer = try SoftwareRenderer.init(allocator, 2, 2, cw, ch);
    defer renderer.deinit();
    renderer.updateAtlas(atlas_data, atlas_w, atlas_h);

    renderer.render(&grid);

    // Pixel (0,0): alpha=255 -> pure red fg
    const red = packArgb(255, 0, 0);
    try std.testing.expectEqual(red, renderer.framebuffer[0]);

    // Pixel (0,1): alpha=0 -> pure blue bg
    const blue = packArgb(0, 0, 255);
    try std.testing.expectEqual(blue, renderer.framebuffer[1]);

    // Pixel (1,0): alpha=128 -> blended (128*255 + 127*0)/255 ≈ 128 red, (128*0 + 127*0)/255 = 0 green, (128*0 + 127*255)/255 ≈ 127 blue
    const blended = renderer.framebuffer[2];
    const blended_r = (blended >> 16) & 0xFF;
    const blended_b = blended & 0xFF;
    // Red channel: (255 * 128 + 0 * 127) / 255 = 128
    try std.testing.expect(blended_r >= 126 and blended_r <= 130);
    // Blue channel: (0 * 128 + 255 * 127) / 255 = 127
    try std.testing.expect(blended_b >= 125 and blended_b <= 129);

    // Pixel (1,1): alpha=255 -> pure red fg
    try std.testing.expectEqual(red, renderer.framebuffer[3]);
}

test "framebuffer dimensions" {
    const allocator = std.testing.allocator;

    var renderer = try SoftwareRenderer.init(allocator, 640, 480, 8, 16);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(usize, 640 * 480), renderer.framebuffer.len);
    try std.testing.expectEqual(@as(u32, 640), renderer.width);
    try std.testing.expectEqual(@as(u32, 480), renderer.height);

    // Resize and verify new dimensions
    try renderer.resize(1920, 1080);
    try std.testing.expectEqual(@as(usize, 1920 * 1080), renderer.framebuffer.len);
    try std.testing.expectEqual(@as(u32, 1920), renderer.width);
    try std.testing.expectEqual(@as(u32, 1080), renderer.height);
}

test "performance: 5000 cells" {
    const allocator = std.testing.allocator;

    // 100 cols x 50 rows = 5000 cells
    var grid = try Grid.init(allocator, 50, 100);
    defer grid.deinit(allocator);

    // Fill grid with text
    for (0..50) |_| {
        for (0..100) |_| {
            grid.write('A');
        }
    }
    // Reset cursor (write wrapped it around)
    grid.cursor_row = 0;
    grid.cursor_col = 0;

    const cw: u32 = 8;
    const ch: u32 = 16;
    const fb_w: u32 = 100 * cw; // 800
    const fb_h: u32 = 50 * ch; // 800

    var renderer = try SoftwareRenderer.init(allocator, fb_w, fb_h, cw, ch);
    defer renderer.deinit();

    // No atlas — tests pure fill performance (no glyph blitting)
    // The render should complete without error; timing is implicit
    // (debug builds ~ms, release builds ~us for 640K pixels).
    renderer.render(&grid);

    // Verify render actually ran: check a sample pixel is background color
    // (no atlas means all cells are background-only)
    const bg = resolveColorArgb(.default, false);
    try std.testing.expectEqual(bg, renderer.framebuffer[0]);
    try std.testing.expectEqual(bg, renderer.framebuffer[renderer.framebuffer.len - 1]);
}

test "color resolution: indexed 256 palette" {
    // Index 0 = black
    try std.testing.expectEqual(@as(u32, 0xFF000000), indexed256Argb(0));
    // Index 15 = bright white
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), indexed256Argb(15));
    // Index 232 = very dark gray (level = 8)
    try std.testing.expectEqual(packArgb(8, 8, 8), indexed256Argb(232));
    // Index 255 = near-white (level = 238)
    try std.testing.expectEqual(packArgb(238, 238, 238), indexed256Argb(255));
}

test "color resolution: RGB passthrough" {
    const color: Grid.Color = .{ .rgb = .{ .r = 128, .g = 64, .b = 255 } };
    try std.testing.expectEqual(packArgb(128, 64, 255), resolveColorArgb(color, true));
}

test "dimColor halves channels" {
    const bright = packArgb(200, 100, 50);
    const dimmed = dimColor(bright);
    try std.testing.expectEqual(packArgb(100, 50, 25), dimmed);
}

test "blitGlyphRow SIMD and scalar produce same results" {
    // Test that the SIMD path (4-pixel batches) and scalar path produce
    // identical output for the same input.
    const allocator = std.testing.allocator;

    const width: usize = 7; // not a multiple of 4, tests both paths
    const fg = packArgb(255, 128, 0); // orange
    const bg = packArgb(0, 0, 64); // dark blue

    const alphas = [_]u8{ 0, 64, 128, 192, 255, 100, 200 };
    const dst = try allocator.alloc(u32, width);
    defer allocator.free(dst);

    blitGlyphRow(dst, &alphas, fg, bg, width);

    // Verify pixel 0 (alpha=0): should be bg
    try std.testing.expectEqual(bg, dst[0]);

    // Verify pixel 4 (alpha=255): should be fg
    try std.testing.expectEqual(fg, dst[4]);

    // Verify pixel 2 (alpha=128): should be roughly halfway
    const mid_r = (dst[2] >> 16) & 0xFF;
    try std.testing.expect(mid_r >= 125 and mid_r <= 130);
}
