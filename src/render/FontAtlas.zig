//! Font atlas builder using FreeType for glyph rasterization and
//! fontconfig for system font discovery.
//!
//! Renders ASCII printable glyphs (32-126) into a single-channel
//! grayscale texture atlas suitable for GPU upload. Glyph metrics
//! are stored for quick lookup by codepoint.
//!
//! C library dependencies (freetype2, fontconfig) are loaded via
//! manually declared extern functions. The build step must link
//! these libraries (via linkSystemLibrary) for init() to work.
//! When not linked, the linker won't resolve the symbols, but
//! tests that don't call init() will still compile and pass.

const std = @import("std");
const FontAtlas = @This();

// ── FreeType C bindings (minimal, hand-declared) ────────────────────
// These match the FreeType 2 ABI. We declare only what we use to avoid
// depending on ft2build.h / freetype.h at compile time.

const FT_Library = ?*anyopaque;
const FT_Face = ?*FT_FaceRec;
const FT_Error = c_int;
const FT_Long = c_long;
const FT_UInt = c_uint;
const FT_Int32 = i32;
const FT_ULong = c_ulong;
const FT_F26Dot6 = c_long;

const FT_LOAD_RENDER: FT_Int32 = 1 << 2; // 4

const FT_Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: ?[*]u8,
    num_grays: c_ushort,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,
};

const FT_Vector = extern struct {
    x: c_long,
    y: c_long,
};

const FT_Glyph_Metrics = extern struct {
    width: FT_F26Dot6,
    height: FT_F26Dot6,
    horiBearingX: FT_F26Dot6,
    horiBearingY: FT_F26Dot6,
    horiAdvance: FT_F26Dot6,
    vertBearingX: FT_F26Dot6,
    vertBearingY: FT_F26Dot6,
    vertAdvance: FT_F26Dot6,
};

const FT_GlyphSlotRec = extern struct {
    library: ?*anyopaque,
    face: ?*anyopaque,
    next: ?*anyopaque,
    glyph_index: FT_UInt,
    generic: extern struct { data: ?*anyopaque, finalizer: ?*anyopaque },
    metrics: FT_Glyph_Metrics,
    linearHoriAdvance: c_long,
    linearVertAdvance: c_long,
    advance: FT_Vector,
    format: c_long, // FT_Glyph_Format
    bitmap: FT_Bitmap,
    bitmap_left: c_int,
    bitmap_top: c_int,
    // ... more fields follow but we don't access them
};

const FT_Size_Metrics = extern struct {
    x_ppem: c_ushort,
    y_ppem: c_ushort,
    x_scale: c_long,
    y_scale: c_long,
    ascender: FT_F26Dot6,
    descender: FT_F26Dot6,
    height: FT_F26Dot6,
    max_advance: FT_F26Dot6,
};

const FT_SizeRec = extern struct {
    face: ?*anyopaque,
    generic: extern struct { data: ?*anyopaque, finalizer: ?*anyopaque },
    metrics: FT_Size_Metrics,
    // ... more fields follow
};

const FT_FaceRec = extern struct {
    num_faces: FT_Long,
    face_index: FT_Long,
    face_flags: FT_Long,
    style_flags: FT_Long,
    num_glyphs: FT_Long,
    family_name: ?[*:0]const u8,
    style_name: ?[*:0]const u8,
    num_fixed_sizes: c_int,
    available_sizes: ?*anyopaque,
    num_charmaps: c_int,
    charmaps: ?*anyopaque,
    generic: extern struct { data: ?*anyopaque, finalizer: ?*anyopaque },
    bbox: extern struct { xMin: c_long, yMin: c_long, xMax: c_long, yMax: c_long },
    units_per_EM: c_ushort,
    ascender: c_short,
    descender: c_short,
    height: c_short,
    max_advance_width: c_short,
    max_advance_height: c_short,
    underline_position: c_short,
    underline_thickness: c_short,
    glyph: ?*FT_GlyphSlotRec,
    size: ?*FT_SizeRec,
    // ... more fields follow
};

extern "freetype" fn FT_Init_FreeType(lib: *FT_Library) callconv(.c) FT_Error;
extern "freetype" fn FT_Done_FreeType(lib: FT_Library) callconv(.c) FT_Error;
extern "freetype" fn FT_New_Face(lib: FT_Library, path: [*:0]const u8, face_index: FT_Long, face: *FT_Face) callconv(.c) FT_Error;
extern "freetype" fn FT_Done_Face(face: FT_Face) callconv(.c) FT_Error;
extern "freetype" fn FT_Set_Pixel_Sizes(face: FT_Face, width: FT_UInt, height: FT_UInt) callconv(.c) FT_Error;
extern "freetype" fn FT_Load_Char(face: FT_Face, char_code: FT_ULong, load_flags: FT_Int32) callconv(.c) FT_Error;

// ── Fontconfig C bindings (minimal) ─────────────────────────────────

const FcConfig = anyopaque;
const FcPattern = anyopaque;
const FcChar8 = u8;
const FcResult = c_int;
const FcMatchKind = c_int;

const FC_FAMILY = "family";
const FC_SPACING = "spacing";
const FC_FILE = "file";
const FC_MONO: c_int = 100;
const FcResultMatch: FcResult = 0;
const FcMatchPattern: FcMatchKind = 0;

extern "fontconfig" fn FcInitLoadConfigAndFonts() callconv(.c) ?*FcConfig;
extern "fontconfig" fn FcConfigDestroy(config: *FcConfig) callconv(.c) void;
extern "fontconfig" fn FcPatternCreate() callconv(.c) ?*FcPattern;
extern "fontconfig" fn FcPatternDestroy(pattern: *FcPattern) callconv(.c) void;
extern "fontconfig" fn FcPatternAddString(pattern: *FcPattern, object: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int;
extern "fontconfig" fn FcPatternAddInteger(pattern: *FcPattern, object: [*:0]const u8, value: c_int) callconv(.c) c_int;
extern "fontconfig" fn FcConfigSubstitute(config: *FcConfig, pattern: *FcPattern, kind: FcMatchKind) callconv(.c) c_int;
extern "fontconfig" fn FcDefaultSubstitute(pattern: *FcPattern) callconv(.c) void;
extern "fontconfig" fn FcFontMatch(config: *FcConfig, pattern: *FcPattern, result: *FcResult) callconv(.c) ?*FcPattern;
extern "fontconfig" fn FcPatternGetString(pattern: *FcPattern, object: [*:0]const u8, n: c_int, value: *[*:0]const FcChar8) callconv(.c) FcResult;

// ── Glyph info ──────────────────────────────────────────────────────

pub const GlyphInfo = struct {
    atlas_x: u16, // position in atlas texture (pixels)
    atlas_y: u16,
    width: u16, // glyph bitmap dimensions
    height: u16,
    bearing_x: i16, // offset from cursor to glyph origin
    bearing_y: i16,
    advance: u16, // horizontal advance (pixels)
};

// ── Atlas fields ────────────────────────────────────────────────────

atlas_data: []u8, // grayscale bitmap (1 byte per pixel)
atlas_width: u32,
atlas_height: u32,
glyphs: [256]?GlyphInfo, // quick lookup for codepoints 0-255
cell_width: u32, // monospace cell dimensions (pixels)
cell_height: u32,
allocator: std.mem.Allocator,

// ── Public API ──────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, font_path: ?[]const u8, font_size: u16) !FontAtlas {
    // Init FreeType
    var ft_lib: FT_Library = null;
    if (FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;
    defer _ = FT_Done_FreeType(ft_lib);

    // Resolve font path
    var resolved_path_buf: ?[:0]const u8 = null;
    defer if (resolved_path_buf) |p| allocator.free(p);

    const path: [*:0]const u8 = if (font_path) |fp| blk: {
        // Caller provided a path; copy to a null-terminated buffer
        const buf = try allocator.allocSentinel(u8, fp.len, 0);
        @memcpy(buf[0..fp.len], fp);
        resolved_path_buf = buf;
        break :blk buf;
    } else blk: {
        // Find system monospace font via fontconfig
        const sys = try findSystemFontImpl(allocator);
        resolved_path_buf = sys;
        break :blk sys.ptr;
    };

    // Load font face
    var face: FT_Face = null;
    if (FT_New_Face(ft_lib, path, 0, &face) != 0) return error.FontLoadFailed;
    defer _ = FT_Done_Face(face);

    // Set pixel size
    if (FT_Set_Pixel_Sizes(face, 0, font_size) != 0) return error.FontSizeSetFailed;

    // Determine cell dimensions from the font metrics.
    // For monospace fonts, all glyphs have the same advance.
    // Use the 'M' glyph as reference.
    if (FT_Load_Char(face, 'M', FT_LOAD_RENDER) != 0) return error.GlyphLoadFailed;

    const face_rec = face.?;
    const metrics = face_rec.size.?.metrics;
    const cell_h: u32 = @intCast(@divTrunc(metrics.height + 63, 64)); // ascender + descender, rounded up
    const cell_w: u32 = @intCast(@divTrunc(face_rec.glyph.?.advance.x + 63, 64));

    // Calculate atlas dimensions
    // Pack glyphs in rows: printable ASCII is 95 characters (32-126)
    const glyph_count: u32 = 95; // ' ' to '~'
    const glyphs_per_row: u32 = 16;
    const atlas_rows: u32 = (glyph_count + glyphs_per_row - 1) / glyphs_per_row;

    // Round up to power of 2 for GPU friendliness
    var atlas_w: u32 = nextPow2(glyphs_per_row * cell_w);
    var atlas_h: u32 = nextPow2(atlas_rows * cell_h);

    // Minimum atlas size
    if (atlas_w < 64) atlas_w = 64;
    if (atlas_h < 64) atlas_h = 64;

    // Allocate atlas bitmap (zero-initialized)
    const atlas_data = try allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h));
    @memset(atlas_data, 0);

    // Render each glyph
    var glyphs_table: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;

    for (0..glyph_count) |i| {
        const cp: u32 = @intCast(i + 32);
        if (FT_Load_Char(face, cp, FT_LOAD_RENDER) != 0) continue;

        const glyph = face_rec.glyph.?;
        const bmp = glyph.bitmap;
        const bmp_w: u32 = bmp.width;
        const bmp_h: u32 = bmp.rows;

        // Atlas position for this glyph
        const grid_col: u32 = @intCast(i % glyphs_per_row);
        const grid_row: u32 = @intCast(i / glyphs_per_row);
        const ax: u32 = grid_col * cell_w;
        const ay: u32 = grid_row * cell_h;

        // Copy bitmap into atlas
        if (bmp.buffer) |buf| {
            if (bmp_w > 0 and bmp_h > 0) {
                const src_pitch: u32 = if (bmp.pitch >= 0)
                    @intCast(bmp.pitch)
                else
                    @intCast(-bmp.pitch);

                for (0..bmp_h) |row| {
                    const dst_y = ay + @as(u32, @intCast(row));
                    if (dst_y >= atlas_h) break;

                    for (0..bmp_w) |col| {
                        const dst_x = ax + @as(u32, @intCast(col));
                        if (dst_x >= atlas_w) break;

                        const dst_idx = @as(usize, dst_y) * @as(usize, atlas_w) + @as(usize, dst_x);
                        const src_idx = @as(usize, row) * @as(usize, src_pitch) + @as(usize, col);
                        atlas_data[dst_idx] = buf[src_idx];
                    }
                }
            }
        }

        glyphs_table[cp] = .{
            .atlas_x = @intCast(ax),
            .atlas_y = @intCast(ay),
            .width = @intCast(bmp_w),
            .height = @intCast(bmp_h),
            .bearing_x = @intCast(glyph.bitmap_left),
            .bearing_y = @intCast(glyph.bitmap_top),
            .advance = @intCast(@divTrunc(glyph.advance.x + 32, 64)),
        };
    }

    return .{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs_table,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = allocator,
    };
}

pub fn deinit(self: *FontAtlas) void {
    self.allocator.free(self.atlas_data);
    self.atlas_data = &.{};
    self.atlas_width = 0;
    self.atlas_height = 0;
}

/// Look up glyph metrics for a codepoint. Returns null if the glyph
/// is not in the atlas.
pub fn getGlyph(self: *const FontAtlas, codepoint: u21) ?GlyphInfo {
    if (codepoint < 256) {
        return self.glyphs[codepoint];
    }
    // Extended codepoints not in the quick-lookup table
    return null;
}

/// Find the default monospace font path using fontconfig.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn findSystemFont(allocator: std.mem.Allocator) ![:0]const u8 {
    return findSystemFontImpl(allocator);
}

// ── Fontconfig implementation ───────────────────────────────────────

fn findSystemFontImpl(allocator: std.mem.Allocator) ![:0]const u8 {
    const config = FcInitLoadConfigAndFonts() orelse return error.FontconfigInitFailed;
    defer FcConfigDestroy(config);

    const pattern = FcPatternCreate() orelse return error.FontconfigPatternFailed;
    defer FcPatternDestroy(pattern);

    // Request a monospace font
    _ = FcPatternAddString(pattern, FC_FAMILY, "monospace");
    _ = FcPatternAddInteger(pattern, FC_SPACING, FC_MONO);

    _ = FcConfigSubstitute(config, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);

    var result: FcResult = FcResultMatch;
    const match = FcFontMatch(config, pattern, &result) orelse return error.FontNotFound;
    defer FcPatternDestroy(match);

    if (result != FcResultMatch) return error.FontNotFound;

    var file_path: [*:0]const FcChar8 = undefined;
    if (FcPatternGetString(match, FC_FILE, 0, &file_path) != FcResultMatch) {
        return error.FontPathNotFound;
    }

    // Copy the path — fontconfig owns the original string
    const path_slice = std.mem.sliceTo(file_path, 0);
    const buf = try allocator.allocSentinel(u8, path_slice.len, 0);
    @memcpy(buf[0..path_slice.len], path_slice);
    return buf;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Round up to the next power of 2. Returns at least 1.
fn nextPow2(v: u32) u32 {
    if (v == 0) return 1;
    var n = v - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
}

// ── Tests ───────────────────────────────────────────────────────────

test "GlyphInfo struct size" {
    // 4 * u16 + 2 * i16 + 1 * u16 = 7 * 2 = 14 bytes
    try std.testing.expectEqual(@as(usize, 14), @sizeOf(GlyphInfo));
}

test "nextPow2" {
    try std.testing.expectEqual(@as(u32, 1), nextPow2(0));
    try std.testing.expectEqual(@as(u32, 1), nextPow2(1));
    try std.testing.expectEqual(@as(u32, 2), nextPow2(2));
    try std.testing.expectEqual(@as(u32, 4), nextPow2(3));
    try std.testing.expectEqual(@as(u32, 256), nextPow2(200));
    try std.testing.expectEqual(@as(u32, 512), nextPow2(257));
    try std.testing.expectEqual(@as(u32, 1024), nextPow2(1024));
}

test "FontAtlas fields have expected defaults" {
    // Verify the null-initialized glyphs table
    const table: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    try std.testing.expect(table[0] == null);
    try std.testing.expect(table[65] == null);
    try std.testing.expect(table[255] == null);
}

test "getGlyph returns null for empty atlas" {
    var atlas = FontAtlas{
        .atlas_data = &.{},
        .atlas_width = 0,
        .atlas_height = 0,
        .glyphs = [_]?GlyphInfo{null} ** 256,
        .cell_width = 0,
        .cell_height = 0,
        .allocator = std.testing.allocator,
    };
    // Nothing to deinit — atlas_data is empty

    try std.testing.expect(atlas.getGlyph('A') == null);
    try std.testing.expect(atlas.getGlyph(0) == null);
    try std.testing.expect(atlas.getGlyph(200) == null);

    // Manually set a glyph and verify lookup
    atlas.glyphs['X'] = .{
        .atlas_x = 10,
        .atlas_y = 20,
        .width = 8,
        .height = 16,
        .bearing_x = 0,
        .bearing_y = 14,
        .advance = 8,
    };
    const g = atlas.getGlyph('X');
    try std.testing.expect(g != null);
    try std.testing.expectEqual(@as(u16, 10), g.?.atlas_x);
    try std.testing.expectEqual(@as(u16, 8), g.?.advance);

    // Out-of-range codepoint
    try std.testing.expect(atlas.getGlyph(0x1F600) == null);
}
