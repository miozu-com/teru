//! OpenGL 4.6 core profile renderer for the terminal character grid.
//!
//! Draws the grid in a single instanced draw call: one quad per cell,
//! textured from the font atlas, with per-cell foreground/background
//! colors. All GL function pointers are loaded at init time via a
//! platform-supplied getProcAddress callback, so this module has zero
//! compile-time dependency on any specific GL loader or windowing system.

const std = @import("std");
const Grid = @import("../core/Grid.zig");

// ── OpenGL types (matching GL/glcorearb.h) ──────────────────────────

const GLuint = u32;
const GLint = i32;
const GLsizei = i32;
const GLenum = u32;
const GLfloat = f32;
const GLboolean = u8;
const GLchar = u8;
const GLbitfield = u32;
const GLsizeiptr = isize;

// ── OpenGL constants ────────────────────────────────────────────────

const GL_FALSE: GLboolean = 0;
const GL_TRUE: GLboolean = 1;
const GL_TRIANGLES: GLenum = 0x0004;
const GL_TRIANGLE_STRIP: GLenum = 0x0005;
const GL_UNSIGNED_BYTE: GLenum = 0x1401;
const GL_FLOAT: GLenum = 0x1406;
const GL_BLEND: GLenum = 0x0BE2;
const GL_SRC_ALPHA: GLenum = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE0: GLenum = 0x84C0;
const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
const GL_LINEAR: GLint = 0x2601;
const GL_CLAMP_TO_EDGE: GLint = 0x812F;
const GL_RED: GLenum = 0x1903;
const GL_R8: GLint = 0x8229;
const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
const GL_VERTEX_SHADER: GLenum = 0x8B31;
const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
const GL_COMPILE_STATUS: GLenum = 0x8B81;
const GL_LINK_STATUS: GLenum = 0x8B82;
const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;
const GL_ARRAY_BUFFER: GLenum = 0x8889;
const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
const GL_STATIC_DRAW: GLenum = 0x88E4;

// ── GL function pointer types ───────────────────────────────────────

const GetProcAddressFn = *const fn ([*:0]const u8) ?*const anyopaque;

const GlFn = struct {
    // Shader
    createShader: *const fn (GLenum) callconv(.c) GLuint = undefined,
    shaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const GLchar, ?[*]const GLint) callconv(.c) void = undefined,
    compileShader: *const fn (GLuint) callconv(.c) void = undefined,
    getShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void = undefined,
    getShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void = undefined,
    deleteShader: *const fn (GLuint) callconv(.c) void = undefined,

    // Program
    createProgram: *const fn () callconv(.c) GLuint = undefined,
    attachShader: *const fn (GLuint, GLuint) callconv(.c) void = undefined,
    linkProgram: *const fn (GLuint) callconv(.c) void = undefined,
    getProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void = undefined,
    getProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]GLchar) callconv(.c) void = undefined,
    useProgram: *const fn (GLuint) callconv(.c) void = undefined,
    deleteProgram: *const fn (GLuint) callconv(.c) void = undefined,
    getUniformLocation: *const fn (GLuint, [*:0]const GLchar) callconv(.c) GLint = undefined,
    uniform1i: *const fn (GLint, GLint) callconv(.c) void = undefined,
    uniform2f: *const fn (GLint, GLfloat, GLfloat) callconv(.c) void = undefined,
    uniform4f: *const fn (GLint, GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void = undefined,

    // VAO / VBO
    genVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void = undefined,
    deleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void = undefined,
    bindVertexArray: *const fn (GLuint) callconv(.c) void = undefined,
    genBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void = undefined,
    deleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void = undefined,
    bindBuffer: *const fn (GLenum, GLuint) callconv(.c) void = undefined,
    bufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void = undefined,
    bufferSubData: *const fn (GLenum, GLsizeiptr, GLsizeiptr, *const anyopaque) callconv(.c) void = undefined,

    // Vertex attribs
    enableVertexAttribArray: *const fn (GLuint) callconv(.c) void = undefined,
    vertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void = undefined,
    vertexAttribDivisor: *const fn (GLuint, GLuint) callconv(.c) void = undefined,

    // Draw
    drawArraysInstanced: *const fn (GLenum, GLint, GLsizei, GLsizei) callconv(.c) void = undefined,

    // Texture
    genTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void = undefined,
    deleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void = undefined,
    bindTexture: *const fn (GLenum, GLuint) callconv(.c) void = undefined,
    activeTexture: *const fn (GLenum) callconv(.c) void = undefined,
    texParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void = undefined,
    texImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void = undefined,
    texSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void = undefined,
    pixelStorei: *const fn (GLenum, GLint) callconv(.c) void = undefined,

    // State
    enable: *const fn (GLenum) callconv(.c) void = undefined,
    disable: *const fn (GLenum) callconv(.c) void = undefined,
    blendFunc: *const fn (GLenum, GLenum) callconv(.c) void = undefined,
    viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void = undefined,
    clearColor: *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void = undefined,
    clear: *const fn (GLbitfield) callconv(.c) void = undefined,
};

fn loadGlFn(getProcAddress: GetProcAddressFn, comptime name: [*:0]const u8) ?*const anyopaque {
    return getProcAddress(name);
}

fn loadGl(getProcAddress: GetProcAddressFn) !GlFn {
    var f: GlFn = .{};

    inline for (@typeInfo(GlFn).@"struct".fields) |field| {
        const gl_name = comptime glName(field.name);
        const ptr = getProcAddress(gl_name) orelse return error.GlFunctionNotFound;
        @field(f, field.name) = @ptrCast(ptr);
    }

    return f;
}

/// Convert a camelCase Zig field name to the "glCamelCase" GL function name.
/// e.g., "createShader" -> "glCreateShader", "texImage2D" -> "glTexImage2D"
inline fn glName(comptime field_name: []const u8) [*:0]const u8 {
    const len = 2 + field_name.len;
    comptime {
        var buf: [len:0]u8 = undefined;
        buf[0] = 'g';
        buf[1] = 'l';
        buf[2] = field_name[0] - 32; // uppercase first letter
        for (field_name[1..], 0..) |ch, i| {
            buf[3 + i] = ch;
        }
        buf[len] = 0;
        const final = buf;
        return &final;
    }
}

// ── Vertex data ─────────────────────────────────────────────────────

/// Per-cell instance data uploaded to the GPU each frame.
pub const CellVertex = extern struct {
    col: GLfloat,
    row: GLfloat,
    glyph_x: GLfloat,
    glyph_y: GLfloat,
    glyph_w: GLfloat,
    glyph_h: GLfloat,
    fg_r: GLfloat,
    fg_g: GLfloat,
    fg_b: GLfloat,
    bg_r: GLfloat,
    bg_g: GLfloat,
    bg_b: GLfloat,
};

// ── Shaders ─────────────────────────────────────────────────────────

const vertex_shader_source: [*:0]const u8 =
    \\#version 330 core
    \\
    \\// Per-vertex: unit quad (2 triangles forming a quad via triangle strip)
    \\// Vertices are generated in the shader; no vertex buffer needed for the quad.
    \\
    \\// Per-instance cell data
    \\layout(location = 0) in vec2 a_cell_pos;     // col, row
    \\layout(location = 1) in vec4 a_glyph_rect;   // atlas x, y, w, h (normalized)
    \\layout(location = 2) in vec3 a_fg_color;
    \\layout(location = 3) in vec3 a_bg_color;
    \\
    \\uniform vec2 u_cell_size;      // cell width, height in clip-space units
    \\uniform vec2 u_grid_offset;    // top-left corner offset in clip-space
    \\
    \\out vec2 v_tex_coord;
    \\out vec3 v_fg_color;
    \\out vec3 v_bg_color;
    \\
    \\void main() {
    \\    // Generate unit quad vertex from gl_VertexID (0..3, triangle strip)
    \\    vec2 quad_pos = vec2(
    \\        float(gl_VertexID & 1),        // 0, 1, 0, 1
    \\        float((gl_VertexID >> 1) & 1)  // 0, 0, 1, 1
    \\    );
    \\
    \\    // Cell position in clip space: top-left is (-1, 1), +x right, +y down
    \\    vec2 cell_origin = u_grid_offset + a_cell_pos * u_cell_size;
    \\    vec2 pos = cell_origin + quad_pos * u_cell_size;
    \\
    \\    // Flip Y: OpenGL clip space has +Y up, terminal grid has +Y down
    \\    gl_Position = vec4(pos.x * 2.0 - 1.0, 1.0 - pos.y * 2.0, 0.0, 1.0);
    \\
    \\    // Texture coordinate into the font atlas
    \\    v_tex_coord = a_glyph_rect.xy + quad_pos * a_glyph_rect.zw;
    \\
    \\    v_fg_color = a_fg_color;
    \\    v_bg_color = a_bg_color;
    \\}
;

const fragment_shader_source: [*:0]const u8 =
    \\#version 330 core
    \\
    \\in vec2 v_tex_coord;
    \\in vec3 v_fg_color;
    \\in vec3 v_bg_color;
    \\
    \\uniform sampler2D u_atlas;
    \\
    \\out vec4 frag_color;
    \\
    \\void main() {
    \\    float alpha = texture(u_atlas, v_tex_coord).r;
    \\    vec3 color = mix(v_bg_color, v_fg_color, alpha);
    \\    frag_color = vec4(color, 1.0);
    \\}
;

// ── Default 16-color palette (SGR indexed colors 0-15) ──────────────

const default_palette = [16][3]f32{
    .{ 0.0, 0.0, 0.0 }, // 0  black
    .{ 0.8, 0.0, 0.0 }, // 1  red
    .{ 0.0, 0.8, 0.0 }, // 2  green
    .{ 0.8, 0.8, 0.0 }, // 3  yellow
    .{ 0.0, 0.0, 0.8 }, // 4  blue
    .{ 0.8, 0.0, 0.8 }, // 5  magenta
    .{ 0.0, 0.8, 0.8 }, // 6  cyan
    .{ 0.75, 0.75, 0.75 }, // 7  white
    .{ 0.5, 0.5, 0.5 }, // 8  bright black
    .{ 1.0, 0.0, 0.0 }, // 9  bright red
    .{ 0.0, 1.0, 0.0 }, // 10 bright green
    .{ 1.0, 1.0, 0.0 }, // 11 bright yellow
    .{ 0.0, 0.0, 1.0 }, // 12 bright blue
    .{ 1.0, 0.0, 1.0 }, // 13 bright magenta
    .{ 0.0, 1.0, 1.0 }, // 14 bright cyan
    .{ 1.0, 1.0, 1.0 }, // 15 bright white
};

// ── Renderer ────────────────────────────────────────────────────────

pub const Renderer = struct {
    gl: GlFn,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    atlas_texture: GLuint,
    cell_width: f32,
    cell_height: f32,
    screen_width: u32,
    screen_height: u32,
    atlas_width: u32,
    atlas_height: u32,

    // Uniform locations
    u_cell_size: GLint,
    u_grid_offset: GLint,
    u_atlas: GLint,

    // Instance buffer (CPU side, reused each frame)
    instance_buf: []CellVertex,
    instance_capacity: u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        getProcAddress: GetProcAddressFn,
    ) !Renderer {
        const gl = try loadGl(getProcAddress);

        // Compile shaders
        const program = try compileProgram(gl);

        // Create VAO and instance VBO
        var vao: GLuint = 0;
        var vbo: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.genBuffers(1, @ptrCast(&vbo));

        gl.bindVertexArray(vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, vbo);

        // Allocate initial instance buffer for a reasonable grid size
        const initial_cap: u32 = 256 * 128; // 256 cols x 128 rows
        const buf_size: GLsizeiptr = @intCast(@as(usize, initial_cap) * @sizeOf(CellVertex));
        gl.bufferData(GL_ARRAY_BUFFER, buf_size, null, GL_DYNAMIC_DRAW);

        // Set up vertex attributes (all per-instance)
        const stride: GLsizei = @intCast(@sizeOf(CellVertex));

        // location 0: a_cell_pos (col, row) — 2 floats
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(0));
        gl.vertexAttribDivisor(0, 1);

        // location 1: a_glyph_rect (x, y, w, h) — 4 floats
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(GLfloat)));
        gl.vertexAttribDivisor(1, 1);

        // location 2: a_fg_color — 3 floats
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(6 * @sizeOf(GLfloat)));
        gl.vertexAttribDivisor(2, 1);

        // location 3: a_bg_color — 3 floats
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 3, GL_FLOAT, GL_FALSE, stride, @ptrFromInt(9 * @sizeOf(GLfloat)));
        gl.vertexAttribDivisor(3, 1);

        gl.bindVertexArray(0);

        // Create atlas texture (1x1 white pixel placeholder)
        var atlas_tex: GLuint = 0;
        gl.genTextures(1, @ptrCast(&atlas_tex));
        gl.bindTexture(GL_TEXTURE_2D, atlas_tex);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        const white_pixel: [1]u8 = .{0xFF};
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_R8, 1, 1, 0, GL_RED, GL_UNSIGNED_BYTE, &white_pixel);

        // Get uniform locations
        gl.useProgram(program);
        const u_cell_size = gl.getUniformLocation(program, "u_cell_size");
        const u_grid_offset = gl.getUniformLocation(program, "u_grid_offset");
        const u_atlas = gl.getUniformLocation(program, "u_atlas");
        gl.uniform1i(u_atlas, 0); // texture unit 0

        // Allocate CPU-side instance buffer
        const instance_buf = try allocator.alloc(CellVertex, initial_cap);

        // Enable blending for text rendering
        gl.enable(GL_BLEND);
        gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        return .{
            .gl = gl,
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .atlas_texture = atlas_tex,
            .cell_width = 8.0, // placeholder until atlas provides real metrics
            .cell_height = 16.0,
            .screen_width = width,
            .screen_height = height,
            .atlas_width = 1,
            .atlas_height = 1,
            .u_cell_size = u_cell_size,
            .u_grid_offset = u_grid_offset,
            .u_atlas = u_atlas,
            .instance_buf = instance_buf,
            .instance_capacity = initial_cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.gl.deleteProgram(self.program);
        self.gl.deleteVertexArrays(1, @ptrCast(&self.vao));
        self.gl.deleteBuffers(1, @ptrCast(&self.vbo));
        self.gl.deleteTextures(1, @ptrCast(&self.atlas_texture));
        self.allocator.free(self.instance_buf);
    }

    /// Render the entire grid to the current framebuffer.
    pub fn render(self: *Renderer, grid: *const Grid) void {
        const gl = self.gl;

        gl.viewport(0, 0, @intCast(self.screen_width), @intCast(self.screen_height));
        gl.clearColor(0.0, 0.0, 0.0, 1.0);
        gl.clear(GL_COLOR_BUFFER_BIT);

        const cell_count: u32 = @as(u32, grid.rows) * @as(u32, grid.cols);
        if (cell_count == 0) return;

        // Grow instance buffer if needed
        if (cell_count > self.instance_capacity) {
            self.allocator.free(self.instance_buf);
            self.instance_buf = self.allocator.alloc(CellVertex, cell_count) catch return;
            self.instance_capacity = cell_count;

            // Reallocate GPU buffer
            gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
            const buf_size: GLsizeiptr = @intCast(@as(usize, cell_count) * @sizeOf(CellVertex));
            gl.bufferData(GL_ARRAY_BUFFER, buf_size, null, GL_DYNAMIC_DRAW);
        }

        // Fill instance data from grid
        const aw: f32 = @floatFromInt(self.atlas_width);
        const ah: f32 = @floatFromInt(self.atlas_height);
        _ = ah;

        var idx: u32 = 0;
        for (0..grid.rows) |r| {
            for (0..grid.cols) |c_idx| {
                const cell = grid.cellAtConst(@intCast(r), @intCast(c_idx));
                const cv = &self.instance_buf[idx];

                cv.col = @floatFromInt(c_idx);
                cv.row = @floatFromInt(r);

                // Glyph atlas lookup — for now, use a simple ASCII mapping.
                // The atlas packs glyphs in a row; each glyph occupies cell_width x cell_height.
                // For codepoints outside the atlas range, render as blank (zero-size glyph).
                const cp = cell.char;
                if (cp >= 32 and cp < 127 and aw > 1.0) {
                    const glyph_idx: f32 = @floatFromInt(cp - 32);
                    const gw = self.cell_width / aw;
                    const gh = self.cell_height / @as(f32, @floatFromInt(self.atlas_height));
                    // Simple row-major packing: glyphs per row
                    const glyphs_per_row = @floor(aw / self.cell_width);
                    const glyph_row = @floor(glyph_idx / glyphs_per_row);
                    const glyph_col = glyph_idx - glyph_row * glyphs_per_row;
                    cv.glyph_x = glyph_col * gw;
                    cv.glyph_y = glyph_row * gh;
                    cv.glyph_w = gw;
                    cv.glyph_h = gh;
                } else {
                    // Non-printable or outside atlas: blank
                    cv.glyph_x = 0;
                    cv.glyph_y = 0;
                    cv.glyph_w = 0;
                    cv.glyph_h = 0;
                }

                // Resolve colors
                const fg = resolveColor(cell.fg, true);
                const bg = resolveColor(cell.bg, false);

                if (cell.attrs.inverse) {
                    cv.fg_r = bg[0];
                    cv.fg_g = bg[1];
                    cv.fg_b = bg[2];
                    cv.bg_r = fg[0];
                    cv.bg_g = fg[1];
                    cv.bg_b = fg[2];
                } else {
                    cv.fg_r = fg[0];
                    cv.fg_g = fg[1];
                    cv.fg_b = fg[2];
                    cv.bg_r = bg[0];
                    cv.bg_g = bg[1];
                    cv.bg_b = bg[2];
                }

                // Dim: reduce foreground brightness
                if (cell.attrs.dim) {
                    cv.fg_r *= 0.5;
                    cv.fg_g *= 0.5;
                    cv.fg_b *= 0.5;
                }

                // Hidden: fg = bg
                if (cell.attrs.hidden) {
                    cv.fg_r = cv.bg_r;
                    cv.fg_g = cv.bg_g;
                    cv.fg_b = cv.bg_b;
                }

                idx += 1;
            }
        }

        // Upload instance data
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        const upload_size: GLsizeiptr = @intCast(@as(usize, cell_count) * @sizeOf(CellVertex));
        gl.bufferSubData(GL_ARRAY_BUFFER, 0, upload_size, @ptrCast(self.instance_buf.ptr));

        // Set uniforms
        gl.useProgram(self.program);

        // Cell size in normalized screen coordinates (0..1)
        const sw: f32 = @floatFromInt(self.screen_width);
        const sh: f32 = @floatFromInt(self.screen_height);
        gl.uniform2f(self.u_cell_size, self.cell_width / sw, self.cell_height / sh);
        gl.uniform2f(self.u_grid_offset, 0.0, 0.0);

        // Bind atlas
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, self.atlas_texture);

        // Draw all cells with instanced rendering: 4 vertices per quad (triangle strip),
        // one instance per cell
        gl.bindVertexArray(self.vao);
        gl.drawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, @intCast(cell_count));
        gl.bindVertexArray(0);
    }

    /// Notify the renderer that the window has been resized.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
    }

    /// Upload a new font atlas texture (single-channel grayscale).
    pub fn updateAtlas(
        self: *Renderer,
        atlas_data: []const u8,
        atlas_width: u32,
        atlas_height: u32,
    ) void {
        self.atlas_width = atlas_width;
        self.atlas_height = atlas_height;

        const gl = self.gl;
        gl.bindTexture(GL_TEXTURE_2D, self.atlas_texture);
        gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.texImage2D(
            GL_TEXTURE_2D,
            0,
            GL_R8,
            @intCast(atlas_width),
            @intCast(atlas_height),
            0,
            GL_RED,
            GL_UNSIGNED_BYTE,
            atlas_data.ptr,
        );
    }

    /// Update cell dimensions (call after loading a new font).
    pub fn setCellSize(self: *Renderer, w: f32, h: f32) void {
        self.cell_width = w;
        self.cell_height = h;
    }
};

// ── Color resolution ────────────────────────────────────────────────

/// Convert a Grid.Color to an RGB float triple.
fn resolveColor(color: Grid.Color, is_fg: bool) [3]f32 {
    return switch (color) {
        .default => if (is_fg)
            .{ 0.9, 0.9, 0.9 } // light gray foreground
        else
            .{ 0.07, 0.07, 0.1 }, // near-black background
        .indexed => |idx| indexed256(idx),
        .rgb => |c| .{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        },
    };
}

/// Convert a 256-color index to RGB floats.
fn indexed256(idx: u8) [3]f32 {
    if (idx < 16) {
        return default_palette[idx];
    } else if (idx < 232) {
        // 6x6x6 color cube (indices 16-231)
        const ci = idx - 16;
        const b_val: u8 = ci % 6;
        const g_val: u8 = (ci / 6) % 6;
        const r_val: u8 = (ci / 36);
        return .{
            if (r_val == 0) @as(f32, 0.0) else @as(f32, @floatFromInt(@as(u16, r_val) * 40 + 55)) / 255.0,
            if (g_val == 0) @as(f32, 0.0) else @as(f32, @floatFromInt(@as(u16, g_val) * 40 + 55)) / 255.0,
            if (b_val == 0) @as(f32, 0.0) else @as(f32, @floatFromInt(@as(u16, b_val) * 40 + 55)) / 255.0,
        };
    } else {
        // Grayscale ramp (indices 232-255): 8, 18, ..., 238
        const level: f32 = @as(f32, @floatFromInt(@as(u16, idx - 232) * 10 + 8)) / 255.0;
        return .{ level, level, level };
    }
}

// ── Shader compilation ──────────────────────────────────────────────

fn compileShader(gl: GlFn, shader_type: GLenum, source: [*:0]const GLchar) !GLuint {
    const shader = gl.createShader(shader_type);
    if (shader == 0) return error.ShaderCreationFailed;

    const sources = [_][*:0]const GLchar{source};
    gl.shaderSource(shader, 1, &sources, null);
    gl.compileShader(shader);

    var status: GLint = 0;
    gl.getShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        gl.deleteShader(shader);
        return error.ShaderCompilationFailed;
    }

    return shader;
}

fn compileProgram(gl: GlFn) !GLuint {
    const vs = try compileShader(gl, GL_VERTEX_SHADER, vertex_shader_source);
    errdefer gl.deleteShader(vs);

    const fs = try compileShader(gl, GL_FRAGMENT_SHADER, fragment_shader_source);
    errdefer gl.deleteShader(fs);

    const program = gl.createProgram();
    if (program == 0) return error.ProgramCreationFailed;

    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);

    var status: GLint = 0;
    gl.getProgramiv(program, GL_LINK_STATUS, &status);
    if (status == 0) {
        gl.deleteProgram(program);
        return error.ProgramLinkFailed;
    }

    // Shaders can be detached after linking; the program owns the compiled code
    gl.deleteShader(vs);
    gl.deleteShader(fs);

    return program;
}

// ── Tests ───────────────────────────────────────────────────────────

test "CellVertex size and alignment" {
    // 12 floats * 4 bytes = 48 bytes per instance
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(CellVertex));
}

test "CellVertex field offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CellVertex, "col"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CellVertex, "row"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CellVertex, "glyph_x"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(CellVertex, "glyph_y"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CellVertex, "glyph_w"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(CellVertex, "glyph_h"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CellVertex, "fg_r"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(CellVertex, "bg_r"));
}

test "Renderer struct is non-zero size" {
    try std.testing.expect(@sizeOf(Renderer) > 0);
}

test "resolveColor default produces expected values" {
    const fg = resolveColor(.default, true);
    try std.testing.expect(fg[0] > 0.5);
    try std.testing.expect(fg[1] > 0.5);

    const bg = resolveColor(.default, false);
    try std.testing.expect(bg[0] < 0.2);
    try std.testing.expect(bg[1] < 0.2);
}

test "resolveColor indexed 256 palette" {
    // Index 0 = black
    const black = indexed256(0);
    try std.testing.expectEqual(@as(f32, 0.0), black[0]);
    try std.testing.expectEqual(@as(f32, 0.0), black[1]);
    try std.testing.expectEqual(@as(f32, 0.0), black[2]);

    // Index 15 = bright white
    const white = indexed256(15);
    try std.testing.expectEqual(@as(f32, 1.0), white[0]);
    try std.testing.expectEqual(@as(f32, 1.0), white[1]);
    try std.testing.expectEqual(@as(f32, 1.0), white[2]);

    // Grayscale ramp: index 232 should be very dark
    const dark_gray = indexed256(232);
    try std.testing.expect(dark_gray[0] < 0.1);
    try std.testing.expect(dark_gray[0] == dark_gray[1]);
    try std.testing.expect(dark_gray[1] == dark_gray[2]);

    // Index 255 should be near-white
    const light_gray = indexed256(255);
    try std.testing.expect(light_gray[0] > 0.9);
}

test "resolveColor RGB passthrough" {
    const c = resolveColor(.{ .rgb = .{ .r = 128, .g = 64, .b = 255 } }, true);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), c[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[2], 0.001);
}

test "glName produces correct GL function names" {
    const createShader = glName("createShader");
    try std.testing.expectEqualStrings("glCreateShader", std.mem.sliceTo(createShader, 0));

    const useProgram = glName("useProgram");
    try std.testing.expectEqualStrings("glUseProgram", std.mem.sliceTo(useProgram, 0));

    const texImage2D = glName("texImage2D");
    try std.testing.expectEqualStrings("glTexImage2D", std.mem.sliceTo(texImage2D, 0));

    const viewport = glName("viewport");
    try std.testing.expectEqualStrings("glViewport", std.mem.sliceTo(viewport, 0));
}
