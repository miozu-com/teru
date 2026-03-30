//! Font atlas builder using stb_truetype (embedded, zero system deps).
//!
//! Rasterizes ASCII printable glyphs (32-126) into a single-channel
//! grayscale texture atlas. Finds fonts by scanning standard paths
//! or accepting an explicit font path. No FreeType, no fontconfig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const compat = @import("../compat.zig");
const FontAtlas = @This();

// ── stb_truetype C bindings ────────────────────────────────────────

const stbtt = @cImport({
    @cInclude("stb_truetype.h");
});

// ── Public types ───────────────────────────────────────────────────

pub const GlyphInfo = struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u16,
    height: u16,
    bearing_x: i16,
    bearing_y: i16,
    advance: u16,
};

// ── Font atlas ─────────────────────────────────────────────────────

atlas_data: []u8,
atlas_width: u32,
atlas_height: u32,
glyphs: [128]?GlyphInfo,
cell_width: u32,
cell_height: u32,
allocator: std.mem.Allocator,
font_data: []u8, // kept alive for stbtt

pub fn init(allocator: std.mem.Allocator, font_path: ?[]const u8, font_size: u16, io: Io) !FontAtlas {
    // Load font file
    const path = font_path orelse try findMonospaceFont(allocator, io);
    const free_path = font_path == null;
    defer if (free_path) allocator.free(path);

    const font_data = try loadFile(allocator, path, io);
    errdefer allocator.free(font_data);

    // Initialize stbtt
    var font_info: stbtt.stbtt_fontinfo = undefined;
    if (stbtt.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    const scale = stbtt.stbtt_ScaleForPixelHeight(&font_info, @floatFromInt(font_size));

    // Get font metrics
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    const f_ascent: f32 = @as(f32, @floatFromInt(ascent)) * scale;
    const f_descent: f32 = @as(f32, @floatFromInt(descent)) * scale;
    const cell_h: u32 = @intFromFloat(@ceil(f_ascent - f_descent));

    // Get advance of 'M' for cell width
    var m_advance: c_int = 0;
    var m_lsb: c_int = 0;
    stbtt.stbtt_GetCodepointHMetrics(&font_info, 'M', &m_advance, &m_lsb);
    const cell_w: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(m_advance)) * scale));

    if (cell_w == 0 or cell_h == 0) return error.InvalidFontMetrics;

    // Atlas layout: 16 glyphs per row, ceil(95/16) = 6 rows
    const glyphs_per_row: u32 = 16;
    const num_glyphs: u32 = 95; // ASCII 32-126
    const num_rows: u32 = (num_glyphs + glyphs_per_row - 1) / glyphs_per_row;
    const atlas_w = glyphs_per_row * cell_w;
    const atlas_h = num_rows * cell_h;

    const atlas_data = try allocator.alloc(u8, atlas_w * atlas_h);
    @memset(atlas_data, 0);

    // Rasterize each glyph
    var glyphs: [128]?GlyphInfo = [_]?GlyphInfo{null} ** 128;
    const baseline: i32 = @intFromFloat(f_ascent);

    for (0..num_glyphs) |i| {
        const codepoint: u21 = @intCast(i + 32);
        const col = i % glyphs_per_row;
        const row = i / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cell_w);
        const atlas_y: u32 = @intCast(row * cell_h);

        // Get glyph metrics
        var advance: c_int = 0;
        var lsb: c_int = 0;
        stbtt.stbtt_GetCodepointHMetrics(&font_info, @intCast(codepoint), &advance, &lsb);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(&font_info, @intCast(codepoint), scale, scale, &ix0, &iy0, &ix1, &iy1);

        const glyph_w: u32 = @intCast(ix1 - ix0);
        const glyph_h: u32 = @intCast(iy1 - iy0);

        if (glyph_w > 0 and glyph_h > 0 and glyph_w <= cell_w and glyph_h <= cell_h) {
            // Render glyph into atlas
            const offset_y: u32 = @intCast(baseline + iy0);
            const offset_x: u32 = @intCast(@max(0, ix0));
            const dst_x = atlas_x + @min(offset_x, cell_w - 1);
            const dst_y = atlas_y + @min(offset_y, cell_h - 1);

            stbtt.stbtt_MakeCodepointBitmap(
                &font_info,
                atlas_data.ptr + dst_y * atlas_w + dst_x,
                @intCast(@min(glyph_w, atlas_w - dst_x)),
                @intCast(@min(glyph_h, atlas_h - dst_y)),
                @intCast(atlas_w),
                scale,
                scale,
                @intCast(codepoint),
            );
        }

        glyphs[codepoint] = GlyphInfo{
            .atlas_x = @intCast(atlas_x),
            .atlas_y = @intCast(atlas_y),
            .width = @intCast(glyph_w),
            .height = @intCast(glyph_h),
            .bearing_x = @intCast(ix0),
            .bearing_y = @intCast(iy0),
            .advance = @intCast(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(advance)) * scale)))),
        };
    }

    return FontAtlas{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = allocator,
        .font_data = font_data,
    };
}

pub fn deinit(self: *FontAtlas) void {
    self.allocator.free(self.atlas_data);
    self.allocator.free(self.font_data);
}

pub fn getGlyph(self: *const FontAtlas, codepoint: u21) ?GlyphInfo {
    if (codepoint < 128) return self.glyphs[codepoint];
    return null;
}

// ── Font discovery (no fontconfig) ─────────────────────────────────

const font_search_paths = [_][]const u8{
    "/usr/share/fonts/TTF",
    "/usr/share/fonts/truetype",
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/truetype/liberation",
    "/usr/share/fonts/truetype/hack",
    "/usr/share/fonts/nerd-fonts",
    "/usr/share/fonts/OTF",
    "/usr/local/share/fonts",
};

const preferred_fonts = [_][]const u8{
    "Hack-Regular.ttf",
    "HackNerdFont-Regular.ttf",
    "DejaVuSansMono.ttf",
    "LiberationMono-Regular.ttf",
    "SourceCodePro-Regular.ttf",
    "JetBrainsMono-Regular.ttf",
    "FiraCode-Regular.ttf",
    "UbuntuMono-Regular.ttf",
    "Inconsolata-Regular.ttf",
    "RobotoMono-Regular.ttf",
    "DroidSansMono.ttf",
};

fn findMonospaceFont(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    // Try preferred fonts in standard paths
    for (font_search_paths) |dir| {
        for (preferred_fonts) |font_name| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, font_name });
            if (Dir.cwd().access(io, path, .{ .read = true })) |_| {
                return path;
            } else |_| {
                allocator.free(path);
            }
        }
    }

    // Try HOME/.local/share/fonts
    if (compat.getenv("HOME")) |home| {
        for (preferred_fonts) |font_name| {
            const path = try std.fmt.allocPrint(allocator, "{s}/.local/share/fonts/{s}", .{ home, font_name });
            if (Dir.cwd().access(io, path, .{ .read = true })) |_| {
                return path;
            } else |_| {
                allocator.free(path);
            }
        }
    }

    return error.NoMonospaceFontFound;
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, io: Io) ![]u8 {
    const file = Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const s = file.stat(io) catch return error.StatFailed;
    const size: usize = @intCast(s.size);
    const data = try allocator.alloc(u8, size);
    const n = file.readPositionalAll(io, data, 0) catch {
        allocator.free(data);
        return error.ReadFailed;
    };
    if (n != size) {
        allocator.free(data);
        return error.IncompleteRead;
    }
    return data;
}

// ── Tests ──────────────────────────────────────────────────────────

test "GlyphInfo has expected fields" {
    const g = GlyphInfo{ .atlas_x = 0, .atlas_y = 0, .width = 8, .height = 16, .bearing_x = 0, .bearing_y = -12, .advance = 8 };
    try std.testing.expectEqual(@as(u16, 8), g.width);
    try std.testing.expectEqual(@as(i16, -12), g.bearing_y);
}

test "preferred font list is not empty" {
    try std.testing.expect(preferred_fonts.len > 0);
    try std.testing.expect(font_search_paths.len > 0);
}
