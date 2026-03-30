const std = @import("std");

/// Character grid for terminal cell data.
/// Stores a flat array of cells (rows * cols) with cursor position
/// and scroll region tracking. The VT parser writes into this grid.
const Grid = @This();

pub const Color = union(enum) {
    default,
    indexed: u8, // 0-255 (standard + 256-color)
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub fn blank() Cell {
        return .{};
    }
};

cells: []Cell,
rows: u16,
cols: u16,
cursor_row: u16 = 0,
cursor_col: u16 = 0,
scroll_top: u16 = 0,
scroll_bottom: u16,
dirty: bool = true,

/// Pen: current attributes applied to newly written cells.
pen_fg: Color = .default,
pen_bg: Color = .default,
pen_attrs: Attrs = .{},

/// Saved cursor state (ESC 7 / ESC[s).
saved_cursor_row: u16 = 0,
saved_cursor_col: u16 = 0,

pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Grid {
    const total = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(Cell, total);
    for (cells) |*c| c.* = Cell.blank();

    return .{
        .cells = cells,
        .rows = rows,
        .cols = cols,
        .scroll_bottom = rows -| 1,
    };
}

pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
    allocator.free(self.cells);
    self.cells = &.{};
}

/// Return a pointer to the cell at (row, col). Clamps to grid bounds.
pub fn cellAt(self: *Grid, row: u16, col: u16) *Cell {
    const r: usize = @min(row, self.rows -| 1);
    const c: usize = @min(col, self.cols -| 1);
    return &self.cells[r * @as(usize, self.cols) + c];
}

/// Return a const pointer to the cell at (row, col). Clamps to grid bounds.
pub fn cellAtConst(self: *const Grid, row: u16, col: u16) *const Cell {
    const r: usize = @min(row, self.rows -| 1);
    const c: usize = @min(col, self.cols -| 1);
    return &self.cells[r * @as(usize, self.cols) + c];
}

/// Write a character at the current cursor position with pen attributes,
/// then advance the cursor. Wraps to the next line at the right margin.
pub fn write(self: *Grid, char: u21) void {
    if (self.cursor_col >= self.cols) {
        // Wrap: move to start of next line
        self.cursor_col = 0;
        self.cursorDown();
    }

    const cell = self.cellAt(self.cursor_row, self.cursor_col);
    cell.char = char;
    cell.fg = self.pen_fg;
    cell.bg = self.pen_bg;
    cell.attrs = self.pen_attrs;

    self.cursor_col += 1;
    self.dirty = true;
}

/// Move the cursor down one row. If at the scroll region bottom, scroll up.
fn cursorDown(self: *Grid) void {
    if (self.cursor_row >= self.scroll_bottom) {
        self.scrollUp();
    } else {
        self.cursor_row += 1;
    }
}

/// Handle newline: move cursor to column 0, then move down (with scroll).
pub fn newline(self: *Grid) void {
    self.cursor_col = 0;
    self.cursorDown();
    self.dirty = true;
}

/// Scroll the scroll region up by one line (content moves up, new blank line at bottom).
pub fn scrollUp(self: *Grid) void {
    self.scrollUpN(1);
}

/// Scroll the scroll region up by n lines.
pub fn scrollUpN(self: *Grid, n: u16) void {
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        // Shift rows up within the scroll region
        var row = top;
        while (row < bottom) : (row += 1) {
            const dst_start = row * w;
            const src_start = (row + 1) * w;
            @memcpy(self.cells[dst_start..][0..w], self.cells[src_start..][0..w]);
        }
        // Clear the bottom row of the scroll region
        self.clearRow(@intCast(bottom));
    }
    self.dirty = true;
}

/// Scroll the scroll region down by one line (content moves down, new blank line at top).
pub fn scrollDown(self: *Grid) void {
    self.scrollDownN(1);
}

/// Scroll the scroll region down by n lines.
pub fn scrollDownN(self: *Grid, n: u16) void {
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        // Shift rows down within the scroll region
        var row = bottom;
        while (row > top) : (row -= 1) {
            const dst_start = row * w;
            const src_start = (row - 1) * w;
            @memcpy(self.cells[dst_start..][0..w], self.cells[src_start..][0..w]);
        }
        // Clear the top row of the scroll region
        self.clearRow(@intCast(top));
    }
    self.dirty = true;
}

/// Clear a single row to blank cells.
fn clearRow(self: *Grid, row: u16) void {
    const start: usize = @as(usize, row) * @as(usize, self.cols);
    const end = start + @as(usize, self.cols);
    for (self.cells[start..end]) |*c| c.* = Cell.blank();
}

/// Clear an entire line (0 = cursor to end, 1 = start to cursor, 2 = whole line).
pub fn clearLine(self: *Grid, row: u16, mode: u8) void {
    const r: usize = @min(row, self.rows -| 1);
    const w: usize = self.cols;
    const row_start = r * w;

    switch (mode) {
        0 => {
            // Cursor to end of line
            const start = row_start + @as(usize, @min(self.cursor_col, self.cols));
            for (self.cells[start..row_start + w]) |*c| c.* = Cell.blank();
        },
        1 => {
            // Start of line to cursor (inclusive)
            const end = row_start + @as(usize, @min(self.cursor_col + 1, self.cols));
            for (self.cells[row_start..end]) |*c| c.* = Cell.blank();
        },
        2 => {
            // Whole line
            self.clearRow(@intCast(r));
        },
        else => {},
    }
    self.dirty = true;
}

/// Clear the screen (0 = cursor to end, 1 = start to cursor, 2 = whole screen, 3 = whole screen + scrollback).
pub fn clearScreen(self: *Grid, mode: u8) void {
    switch (mode) {
        0 => {
            // Cursor to end: clear rest of current line + all lines below
            self.clearLine(self.cursor_row, 0);
            var r = self.cursor_row + 1;
            while (r < self.rows) : (r += 1) {
                self.clearRow(r);
            }
        },
        1 => {
            // Start to cursor: clear all lines above + start of current line
            var r: u16 = 0;
            while (r < self.cursor_row) : (r += 1) {
                self.clearRow(r);
            }
            self.clearLine(self.cursor_row, 1);
        },
        2, 3 => {
            // Whole screen
            for (self.cells) |*c| c.* = Cell.blank();
        },
        else => {},
    }
    self.dirty = true;
}

/// Resize the grid, preserving content where possible.
pub fn resize(self: *Grid, allocator: std.mem.Allocator, new_rows: u16, new_cols: u16) !void {
    const new_total = @as(usize, new_rows) * @as(usize, new_cols);
    const new_cells = try allocator.alloc(Cell, new_total);
    for (new_cells) |*c| c.* = Cell.blank();

    // Copy overlapping region
    const copy_rows = @min(self.rows, new_rows);
    const copy_cols = @min(self.cols, new_cols);

    var r: usize = 0;
    while (r < copy_rows) : (r += 1) {
        const old_start = r * @as(usize, self.cols);
        const new_start = r * @as(usize, new_cols);
        @memcpy(new_cells[new_start..][0..copy_cols], self.cells[old_start..][0..copy_cols]);
    }

    allocator.free(self.cells);
    self.cells = new_cells;
    self.rows = new_rows;
    self.cols = new_cols;
    self.scroll_bottom = new_rows -| 1;
    self.scroll_top = 0;

    // Clamp cursor
    self.cursor_row = @min(self.cursor_row, new_rows -| 1);
    self.cursor_col = @min(self.cursor_col, new_cols -| 1);
    self.dirty = true;
}

/// Set cursor position (1-based coordinates, as per VT convention).
/// Clamps to grid bounds. Pass 0 or 1 for top-left.
pub fn setCursorPos(self: *Grid, row: u16, col: u16) void {
    self.cursor_row = if (row == 0) 0 else @min(row - 1, self.rows -| 1);
    self.cursor_col = if (col == 0) 0 else @min(col - 1, self.cols -| 1);
}

/// Reset pen attributes to defaults.
pub fn resetPen(self: *Grid) void {
    self.pen_fg = .default;
    self.pen_bg = .default;
    self.pen_attrs = .{};
}

/// Save cursor position.
pub fn saveCursor(self: *Grid) void {
    self.saved_cursor_row = self.cursor_row;
    self.saved_cursor_col = self.cursor_col;
}

/// Restore saved cursor position.
pub fn restoreCursor(self: *Grid) void {
    self.cursor_row = @min(self.saved_cursor_row, self.rows -| 1);
    self.cursor_col = @min(self.saved_cursor_col, self.cols -| 1);
}

// ── Tests ────────────────────────────────────────────────────────

test "init and deinit" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 24), grid.rows);
    try std.testing.expectEqual(@as(u16, 80), grid.cols);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
    try std.testing.expectEqual(@as(u16, 23), grid.scroll_bottom);
    try std.testing.expectEqual(@as(usize, 24 * 80), grid.cells.len);

    // All cells should be blank spaces
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(23, 79).char);
}

test "write characters and cursor advance" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.write('H');
    grid.write('i');
    grid.write('!');

    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, '!'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_col);
}

test "write wraps at right margin" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Write 5 chars into a 4-col grid
    grid.write('A');
    grid.write('B');
    grid.write('C');
    grid.write('D');
    // cursor_col is now 4, which == cols. Next write triggers wrap.
    grid.write('E');

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "newline moves cursor and scrolls" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.write('A');
    grid.newline();
    grid.write('B');
    grid.newline();
    grid.write('C');

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(2, 0).char);

    // One more newline should scroll: row 0 ('A') gone, 'B' moves to row 0
    grid.newline();
    grid.write('D');

    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(2, 0).char);
}

test "scrollUp shifts content up" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Fill rows: row 0 = 'A', row 1 = 'B', row 2 = 'C'
    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';

    grid.scrollUp();

    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 0).char); // cleared
}

test "scrollDown shifts content down" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';

    grid.scrollDown();

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char); // cleared
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(2, 0).char);
}

test "clearScreen mode 2 clears all" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.write('X');
    grid.write('Y');
    grid.clearScreen(2);

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
}

test "clearLine modes" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    // Fill row 0
    var col: u16 = 0;
    while (col < 5) : (col += 1) {
        grid.cellAt(0, col).char = 'A' + @as(u21, col);
    }
    // Position cursor at column 2
    grid.cursor_row = 0;
    grid.cursor_col = 2;

    // Mode 0: clear from cursor to end
    grid.clearLine(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
}

test "resize preserves content" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'X';
    grid.cellAt(1, 1).char = 'Y';

    try grid.resize(allocator, 5, 6);

    try std.testing.expectEqual(@as(u16, 5), grid.rows);
    try std.testing.expectEqual(@as(u16, 6), grid.cols);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), grid.cellAtConst(1, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(4, 5).char);
}

test "resize shrinks and clamps cursor" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 10);
    defer grid.deinit(allocator);

    grid.cursor_row = 8;
    grid.cursor_col = 9;

    try grid.resize(allocator, 5, 5);

    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_col);
}

test "setCursorPos 1-based" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.setCursorPos(5, 10);
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);

    // Clamp to bounds
    grid.setCursorPos(100, 200);
    try std.testing.expectEqual(@as(u16, 23), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 79), grid.cursor_col);

    // 0 means 1 (VT convention)
    grid.setCursorPos(0, 0);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
}

test "pen attributes applied to written cells" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    grid.pen_attrs.bold = true;
    grid.pen_fg = .{ .indexed = 1 };
    grid.write('B');

    const cell = grid.cellAtConst(0, 0);
    try std.testing.expect(cell.attrs.bold);
    try std.testing.expectEqual(Color{ .indexed = 1 }, cell.fg);

    grid.resetPen();
    grid.write('N');
    const cell2 = grid.cellAtConst(0, 1);
    try std.testing.expect(!cell2.attrs.bold);
    try std.testing.expectEqual(Color.default, cell2.fg);
}

test "save and restore cursor" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.cursor_row = 5;
    grid.cursor_col = 10;
    grid.saveCursor();

    grid.cursor_row = 20;
    grid.cursor_col = 70;
    grid.restoreCursor();

    try std.testing.expectEqual(@as(u16, 5), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), grid.cursor_col);
}
