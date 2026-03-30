const std = @import("std");
const Allocator = std.mem.Allocator;

const LayoutEngine = @This();

// ── Core types ──────────────────────────────────────────────────

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.width == other.width and self.height == other.height;
    }

    pub const zero = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

pub const Layout = enum {
    master_stack,
    grid,
    monocle,
    floating,
};

pub const Workspace = struct {
    name: []const u8,
    layout: Layout,
    node_ids: std.ArrayListUnmanaged(u64),
    active_index: usize = 0,
    master_ratio: f32 = 0.6,

    fn init(name: []const u8) Workspace {
        return .{
            .name = name,
            .layout = .monocle,
            .node_ids = .{},
        };
    }

    pub fn deinit(self: *Workspace, allocator: Allocator) void {
        self.node_ids.deinit(allocator);
    }

    pub fn addNode(self: *Workspace, allocator: Allocator, id: u64) !void {
        // Prevent duplicates
        for (self.node_ids.items) |existing| {
            if (existing == id) return;
        }
        try self.node_ids.append(allocator, id);
        // Auto-select layout for new count
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }

    pub fn removeNode(self: *Workspace, id: u64) void {
        for (self.node_ids.items, 0..) |existing, i| {
            if (existing == id) {
                _ = self.node_ids.orderedRemove(i);
                break;
            }
        }
        // Clamp active_index
        if (self.node_ids.items.len == 0) {
            self.active_index = 0;
        } else if (self.active_index >= self.node_ids.items.len) {
            self.active_index = self.node_ids.items.len - 1;
        }
        // Auto-select layout for new count
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }

    pub fn focusNext(self: *Workspace) void {
        if (self.node_ids.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.node_ids.items.len;
    }

    pub fn focusPrev(self: *Workspace) void {
        if (self.node_ids.items.len == 0) return;
        if (self.active_index == 0) {
            self.active_index = self.node_ids.items.len - 1;
        } else {
            self.active_index -= 1;
        }
    }

    pub fn swapWithNext(self: *Workspace) void {
        const len = self.node_ids.items.len;
        if (len < 2) return;
        const next = (self.active_index + 1) % len;
        const items = self.node_ids.items;
        const tmp = items[self.active_index];
        items[self.active_index] = items[next];
        items[next] = tmp;
        self.active_index = next;
    }

    pub fn swapWithPrev(self: *Workspace) void {
        const len = self.node_ids.items.len;
        if (len < 2) return;
        const prev = if (self.active_index == 0) len - 1 else self.active_index - 1;
        const items = self.node_ids.items;
        const tmp = items[self.active_index];
        items[self.active_index] = items[prev];
        items[prev] = tmp;
        self.active_index = prev;
    }

    pub fn promoteToMaster(self: *Workspace) void {
        if (self.node_ids.items.len < 2 or self.active_index == 0) return;
        const items = self.node_ids.items;
        const promoted = items[self.active_index];
        // Shift everything between 0..active_index right by one
        var i = self.active_index;
        while (i > 0) : (i -= 1) {
            items[i] = items[i - 1];
        }
        items[0] = promoted;
        self.active_index = 0;
    }

    pub fn getActiveNodeId(self: *const Workspace) ?u64 {
        if (self.node_ids.items.len == 0) return null;
        return self.node_ids.items[self.active_index];
    }

    pub fn nodeCount(self: *const Workspace) usize {
        return self.node_ids.items.len;
    }
};

// ── Layout engine state ─────────────────────────────────────────

allocator: Allocator,
workspaces: [9]Workspace,
active_workspace: u8 = 0,

pub fn init(allocator: Allocator) LayoutEngine {
    var engine: LayoutEngine = .{
        .allocator = allocator,
        .workspaces = undefined,
    };
    const names = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    for (&engine.workspaces, 0..) |*ws, i| {
        ws.* = Workspace.init(names[i]);
    }
    return engine;
}

pub fn deinit(self: *LayoutEngine) void {
    for (&self.workspaces) |*ws| {
        ws.deinit(self.allocator);
    }
}

// ── Layout calculation ──────────────────────────────────────────

/// Compute positioned rectangles for every node in the given workspace.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn calculate(self: *LayoutEngine, workspace_index: u8, screen: Rect) ![]Rect {
    if (workspace_index >= 9) return error.InvalidWorkspace;
    const ws = &self.workspaces[workspace_index];
    const count = ws.node_ids.items.len;

    if (count == 0) {
        return try self.allocator.alloc(Rect, 0);
    }

    return switch (ws.layout) {
        .master_stack => try calculateMasterStack(self.allocator, count, screen, ws.master_ratio),
        .grid => try calculateGrid(self.allocator, count, screen),
        .monocle => try calculateMonocle(self.allocator, count, screen, ws.active_index),
        .floating => try calculateFloating(self.allocator, count, screen),
    };
}

fn calculateMasterStack(allocator: Allocator, count: usize, screen: Rect, ratio: f32) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        // Single node gets the full screen
        rects[0] = screen;
        return rects;
    }

    const master_w: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.width)) * ratio);
    const stack_w: u16 = screen.width - master_w;
    const stack_count: u16 = @intCast(count - 1);

    // Master pane
    rects[0] = .{
        .x = screen.x,
        .y = screen.y,
        .width = master_w,
        .height = screen.height,
    };

    // Stack panes — divide right portion equally
    const cell_h = screen.height / stack_count;
    const remainder = screen.height % stack_count;

    for (0..stack_count) |i| {
        const idx: u16 = @intCast(i);
        // Distribute remainder pixels to the last pane
        const extra: u16 = if (i == stack_count - 1) remainder else 0;
        rects[i + 1] = .{
            .x = screen.x + master_w,
            .y = screen.y + idx * cell_h,
            .width = stack_w,
            .height = cell_h + extra,
        };
    }

    return rects;
}

fn calculateGrid(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    // Calculate optimal grid dimensions: cols = ceil(sqrt(count)), rows = ceil(count/cols)
    const cols = gridCols(count);
    const rows = (count + cols - 1) / cols;

    const cell_w: u16 = screen.width / @as(u16, @intCast(cols));
    const cell_h: u16 = screen.height / @as(u16, @intCast(rows));

    for (0..count) |i| {
        const col = i % cols;
        const row = i / cols;

        // Last column gets remainder width, last row gets remainder height
        const is_last_col = (col == cols - 1);
        const is_last_row = (row == rows - 1);
        const w_extra: u16 = if (is_last_col) screen.width % @as(u16, @intCast(cols)) else 0;
        const h_extra: u16 = if (is_last_row) screen.height % @as(u16, @intCast(rows)) else 0;

        rects[i] = .{
            .x = screen.x + @as(u16, @intCast(col)) * cell_w,
            .y = screen.y + @as(u16, @intCast(row)) * cell_h,
            .width = cell_w + w_extra,
            .height = cell_h + h_extra,
        };
    }

    return rects;
}

fn calculateMonocle(allocator: Allocator, count: usize, screen: Rect, active: usize) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    for (0..count) |i| {
        if (i == active) {
            rects[i] = screen;
        } else {
            rects[i] = Rect.zero;
        }
    }

    return rects;
}

fn calculateFloating(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    // Floating layout: position nodes in a reasonable default (cascading)
    // since we don't store per-node rects yet.
    const rects = try allocator.alloc(Rect, count);

    const default_w = screen.width * 3 / 4;
    const default_h = screen.height * 3 / 4;

    for (0..count) |i| {
        const offset: u16 = @intCast(@min(i * 2, screen.width / 4));
        rects[i] = .{
            .x = screen.x + offset,
            .y = screen.y + offset,
            .width = @min(default_w, screen.width -| offset),
            .height = @min(default_h, screen.height -| offset),
        };
    }

    return rects;
}

/// Optimal column count for a grid of n items.
fn gridCols(n: usize) usize {
    if (n <= 1) return 1;
    var cols: usize = 1;
    while (cols * cols < n) : (cols += 1) {}
    return cols;
}

// ── Workspace management ────────────────────────────────────────

pub fn switchWorkspace(self: *LayoutEngine, index: u8) void {
    if (index < 9) {
        self.active_workspace = index;
    }
}

pub fn moveNodeToWorkspace(self: *LayoutEngine, node_id: u64, target: u8) !void {
    if (target >= 9) return error.InvalidWorkspace;

    // Remove from all workspaces (node might be in any one)
    for (&self.workspaces) |*ws| {
        ws.removeNode(node_id);
    }

    // Add to target
    try self.workspaces[target].addNode(self.allocator, node_id);
}

pub fn getActiveWorkspace(self: *LayoutEngine) *Workspace {
    return &self.workspaces[self.active_workspace];
}

pub fn autoSelectLayout(node_count: usize) Layout {
    return switch (node_count) {
        0, 1 => .monocle,
        2, 3, 4 => .master_stack,
        else => .grid,
    };
}

// ── Tests ───────────────────────────────────────────────────────

test "autoSelectLayout" {
    try std.testing.expectEqual(Layout.monocle, autoSelectLayout(0));
    try std.testing.expectEqual(Layout.monocle, autoSelectLayout(1));
    try std.testing.expectEqual(Layout.master_stack, autoSelectLayout(2));
    try std.testing.expectEqual(Layout.master_stack, autoSelectLayout(3));
    try std.testing.expectEqual(Layout.master_stack, autoSelectLayout(4));
    try std.testing.expectEqual(Layout.grid, autoSelectLayout(5));
    try std.testing.expectEqual(Layout.grid, autoSelectLayout(9));
}

test "gridCols" {
    try std.testing.expectEqual(@as(usize, 1), gridCols(1));
    try std.testing.expectEqual(@as(usize, 2), gridCols(2));
    try std.testing.expectEqual(@as(usize, 2), gridCols(3));
    try std.testing.expectEqual(@as(usize, 2), gridCols(4));
    try std.testing.expectEqual(@as(usize, 3), gridCols(5));
    try std.testing.expectEqual(@as(usize, 3), gridCols(6));
    try std.testing.expectEqual(@as(usize, 3), gridCols(9));
    try std.testing.expectEqual(@as(usize, 4), gridCols(10));
}

test "master_stack layout — single node gets full screen" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 100);
    engine.workspaces[0].layout = .master_stack;

    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expect(rects[0].eql(screen));
}

test "master_stack layout — two nodes" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    try engine.workspaces[0].addNode(allocator, 2);
    engine.workspaces[0].layout = .master_stack;

    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);

    // Master: left 60%
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 600), rects[0].width);
    try std.testing.expectEqual(@as(u16, 800), rects[0].height);

    // Stack: right 40%, full height
    try std.testing.expectEqual(@as(u16, 600), rects[1].x);
    try std.testing.expectEqual(@as(u16, 400), rects[1].width);
    try std.testing.expectEqual(@as(u16, 800), rects[1].height);
}

test "master_stack layout — four nodes" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..5) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .master_stack;
    engine.workspaces[0].master_ratio = 0.5;

    const screen = Rect{ .x = 0, .y = 0, .width = 1200, .height = 900 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 4), rects.len);

    // Master
    try std.testing.expectEqual(@as(u16, 600), rects[0].width);
    try std.testing.expectEqual(@as(u16, 900), rects[0].height);

    // 3 stack panes, each 300px tall
    try std.testing.expectEqual(@as(u16, 600), rects[1].x);
    try std.testing.expectEqual(@as(u16, 0), rects[1].y);
    try std.testing.expectEqual(@as(u16, 300), rects[1].height);

    try std.testing.expectEqual(@as(u16, 600), rects[2].x);
    try std.testing.expectEqual(@as(u16, 300), rects[2].y);
    try std.testing.expectEqual(@as(u16, 300), rects[2].height);

    try std.testing.expectEqual(@as(u16, 600), rects[3].x);
    try std.testing.expectEqual(@as(u16, 600), rects[3].y);
    try std.testing.expectEqual(@as(u16, 300), rects[3].height);
}

test "grid layout — four nodes" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..5) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .grid;

    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 4), rects.len);

    // 2x2 grid, each cell 500x400
    try std.testing.expect(rects[0].eql(.{ .x = 0, .y = 0, .width = 500, .height = 400 }));
    try std.testing.expect(rects[1].eql(.{ .x = 500, .y = 0, .width = 500, .height = 400 }));
    try std.testing.expect(rects[2].eql(.{ .x = 0, .y = 400, .width = 500, .height = 400 }));
    try std.testing.expect(rects[3].eql(.{ .x = 500, .y = 400, .width = 500, .height = 400 }));
}

test "grid layout — six nodes (3x2)" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..7) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .grid;

    const screen = Rect{ .x = 0, .y = 0, .width = 900, .height = 600 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 6), rects.len);

    // 3 cols x 2 rows = 300x300 each
    try std.testing.expectEqual(@as(u16, 300), rects[0].width);
    try std.testing.expectEqual(@as(u16, 300), rects[0].height);
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 0), rects[0].y);

    // Node 3 (index 2) = col 2, row 0
    try std.testing.expectEqual(@as(u16, 600), rects[2].x);
    try std.testing.expectEqual(@as(u16, 0), rects[2].y);

    // Node 4 (index 3) = col 0, row 1
    try std.testing.expectEqual(@as(u16, 0), rects[3].x);
    try std.testing.expectEqual(@as(u16, 300), rects[3].y);
}

test "grid layout — remainder pixels go to last col/row" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..5) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .grid;

    // 1001 / 2 = 500 base + 1 remainder, 801 / 2 = 400 base + 1 remainder
    const screen = Rect{ .x = 0, .y = 0, .width = 1001, .height = 801 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    // Top-left: no extra
    try std.testing.expectEqual(@as(u16, 500), rects[0].width);
    try std.testing.expectEqual(@as(u16, 400), rects[0].height);

    // Top-right: extra width pixel
    try std.testing.expectEqual(@as(u16, 501), rects[1].width);
    try std.testing.expectEqual(@as(u16, 400), rects[1].height);

    // Bottom-left: extra height pixel
    try std.testing.expectEqual(@as(u16, 500), rects[2].width);
    try std.testing.expectEqual(@as(u16, 401), rects[2].height);

    // Bottom-right: extra both
    try std.testing.expectEqual(@as(u16, 501), rects[3].width);
    try std.testing.expectEqual(@as(u16, 401), rects[3].height);
}

test "monocle layout — active node gets full screen" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..4) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .monocle;
    engine.workspaces[0].active_index = 1;

    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    try std.testing.expect(rects[0].eql(Rect.zero));
    try std.testing.expect(rects[1].eql(screen));
    try std.testing.expect(rects[2].eql(Rect.zero));
}

test "floating layout — cascading default positions" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..4) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .floating;

    const screen = Rect{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);

    // First window: no offset
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 600), rects[0].width);
    try std.testing.expectEqual(@as(u16, 450), rects[0].height);

    // Second window: offset by 2
    try std.testing.expectEqual(@as(u16, 2), rects[1].x);
    try std.testing.expectEqual(@as(u16, 2), rects[1].y);
}

test "calculate — zero nodes returns empty slice" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 0), rects.len);
}

test "calculate — invalid workspace returns error" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const screen = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expectError(error.InvalidWorkspace, engine.calculate(9, screen));
    try std.testing.expectError(error.InvalidWorkspace, engine.calculate(255, screen));
}

test "workspace — addNode prevents duplicates" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 42);
    try ws.addNode(allocator, 42);
    try ws.addNode(allocator, 42);

    try std.testing.expectEqual(@as(usize, 1), ws.node_ids.items.len);
}

test "workspace — removeNode clamps active_index" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 1);
    try ws.addNode(allocator, 2);
    try ws.addNode(allocator, 3);
    ws.active_index = 2; // focused on node 3

    ws.removeNode(3);

    try std.testing.expectEqual(@as(usize, 2), ws.node_ids.items.len);
    try std.testing.expectEqual(@as(usize, 1), ws.active_index); // clamped
}

test "workspace — removeNode to empty" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 1);
    ws.removeNode(1);

    try std.testing.expectEqual(@as(usize, 0), ws.node_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), ws.active_index);
    try std.testing.expectEqual(@as(?u64, null), ws.getActiveNodeId());
}

test "workspace — focusNext wraps around" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 1);
    try ws.addNode(allocator, 2);
    try ws.addNode(allocator, 3);

    try std.testing.expectEqual(@as(usize, 0), ws.active_index);
    ws.focusNext();
    try std.testing.expectEqual(@as(usize, 1), ws.active_index);
    ws.focusNext();
    try std.testing.expectEqual(@as(usize, 2), ws.active_index);
    ws.focusNext();
    try std.testing.expectEqual(@as(usize, 0), ws.active_index); // wrapped
}

test "workspace — focusPrev wraps around" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 1);
    try ws.addNode(allocator, 2);
    try ws.addNode(allocator, 3);

    ws.focusPrev();
    try std.testing.expectEqual(@as(usize, 2), ws.active_index); // wrapped to end
    ws.focusPrev();
    try std.testing.expectEqual(@as(usize, 1), ws.active_index);
}

test "workspace — focusNext/Prev no-op on empty" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    ws.focusNext(); // should not crash
    ws.focusPrev(); // should not crash
    try std.testing.expectEqual(@as(usize, 0), ws.active_index);
}

test "workspace — swapWithNext" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);
    try ws.addNode(allocator, 30);

    // active=0 (node 10), swap with next
    ws.swapWithNext();
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try std.testing.expectEqual(@as(usize, 1), ws.active_index); // focus follows
}

test "workspace — swapWithPrev" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);
    try ws.addNode(allocator, 30);

    ws.active_index = 2; // focused on node 30
    ws.swapWithPrev();
    try std.testing.expectEqual(@as(u64, 30), ws.node_ids.items[1]);
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[2]);
    try std.testing.expectEqual(@as(usize, 1), ws.active_index); // focus follows
}

test "workspace — swapWithNext wraps" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);

    ws.active_index = 1;
    ws.swapWithNext(); // wraps: swap index 1 with index 0
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try std.testing.expectEqual(@as(usize, 0), ws.active_index);
}

test "workspace — swapWithPrev wraps" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);

    ws.active_index = 0;
    ws.swapWithPrev(); // wraps: swap index 0 with index 1
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try std.testing.expectEqual(@as(usize, 1), ws.active_index);
}

test "workspace — promoteToMaster" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);
    try ws.addNode(allocator, 30);
    try ws.addNode(allocator, 40);

    ws.active_index = 2; // node 30
    ws.promoteToMaster();

    try std.testing.expectEqual(@as(u64, 30), ws.node_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[2]);
    try std.testing.expectEqual(@as(u64, 40), ws.node_ids.items[3]);
    try std.testing.expectEqual(@as(usize, 0), ws.active_index);
}

test "workspace — promoteToMaster no-op when already master" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try ws.addNode(allocator, 10);
    try ws.addNode(allocator, 20);

    ws.active_index = 0;
    ws.promoteToMaster(); // no-op

    try std.testing.expectEqual(@as(u64, 10), ws.node_ids.items[0]);
    try std.testing.expectEqual(@as(u64, 20), ws.node_ids.items[1]);
}

test "workspace — getActiveNodeId" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    try std.testing.expectEqual(@as(?u64, null), ws.getActiveNodeId());

    try ws.addNode(allocator, 42);
    try std.testing.expectEqual(@as(?u64, 42), ws.getActiveNodeId());

    try ws.addNode(allocator, 99);
    ws.active_index = 1;
    try std.testing.expectEqual(@as(?u64, 99), ws.getActiveNodeId());
}

test "switchWorkspace" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(u8, 0), engine.active_workspace);

    engine.switchWorkspace(3);
    try std.testing.expectEqual(@as(u8, 3), engine.active_workspace);
    try std.testing.expect(std.mem.eql(u8, "4", engine.getActiveWorkspace().name));

    engine.switchWorkspace(8);
    try std.testing.expectEqual(@as(u8, 8), engine.active_workspace);
    try std.testing.expect(std.mem.eql(u8, "9", engine.getActiveWorkspace().name));

    // Out of range — no change
    engine.switchWorkspace(9);
    try std.testing.expectEqual(@as(u8, 8), engine.active_workspace);
    engine.switchWorkspace(255);
    try std.testing.expectEqual(@as(u8, 8), engine.active_workspace);
}

test "moveNodeToWorkspace" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    try engine.workspaces[0].addNode(allocator, 2);
    try engine.workspaces[0].addNode(allocator, 3);

    // Move node 2 from workspace 0 to workspace 3
    try engine.moveNodeToWorkspace(2, 3);

    try std.testing.expectEqual(@as(usize, 2), engine.workspaces[0].nodeCount());
    try std.testing.expectEqual(@as(usize, 1), engine.workspaces[3].nodeCount());
    try std.testing.expectEqual(@as(?u64, 2), engine.workspaces[3].getActiveNodeId());

    // Verify node 2 is gone from workspace 0
    for (engine.workspaces[0].node_ids.items) |id| {
        try std.testing.expect(id != 2);
    }
}

test "moveNodeToWorkspace — invalid target" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectError(error.InvalidWorkspace, engine.moveNodeToWorkspace(1, 9));
}

test "workspace — addNode auto-selects layout" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];

    try ws.addNode(allocator, 1);
    try std.testing.expectEqual(Layout.monocle, ws.layout);

    try ws.addNode(allocator, 2);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    try ws.addNode(allocator, 3);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    try ws.addNode(allocator, 4);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    try ws.addNode(allocator, 5);
    try std.testing.expectEqual(Layout.grid, ws.layout);
}

test "workspace — removeNode auto-selects layout" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    const ws = &engine.workspaces[0];
    for (1..6) |id| {
        try ws.addNode(allocator, @intCast(id));
    }
    try std.testing.expectEqual(Layout.grid, ws.layout);

    ws.removeNode(5);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    ws.removeNode(4);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    ws.removeNode(3);
    try std.testing.expectEqual(Layout.master_stack, ws.layout);

    ws.removeNode(2);
    try std.testing.expectEqual(Layout.monocle, ws.layout);

    ws.removeNode(1);
    try std.testing.expectEqual(Layout.monocle, ws.layout);
}

test "master_stack — screen with offset origin" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    try engine.workspaces[0].addNode(allocator, 2);
    engine.workspaces[0].layout = .master_stack;
    engine.workspaces[0].master_ratio = 0.5;

    // Screen starts at (10, 20) — e.g., inside a border/tab bar
    const screen = Rect{ .x = 10, .y = 20, .width = 800, .height = 600 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(u16, 10), rects[0].x);
    try std.testing.expectEqual(@as(u16, 20), rects[0].y);
    try std.testing.expectEqual(@as(u16, 400), rects[0].width);

    try std.testing.expectEqual(@as(u16, 410), rects[1].x);
    try std.testing.expectEqual(@as(u16, 20), rects[1].y);
    try std.testing.expectEqual(@as(u16, 400), rects[1].width);
}

test "master_stack — remainder height distribution" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    try engine.workspaces[0].addNode(allocator, 2);
    try engine.workspaces[0].addNode(allocator, 3);
    engine.workspaces[0].layout = .master_stack;

    // 100 height / 2 stack panes = 50 each, no remainder
    const screen = Rect{ .x = 0, .y = 0, .width = 100, .height = 101 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    // Stack pane 1: h=50, stack pane 2: h=51 (gets remainder)
    try std.testing.expectEqual(@as(u16, 50), rects[1].height);
    try std.testing.expectEqual(@as(u16, 51), rects[2].height);

    // Verify total coverage
    try std.testing.expectEqual(@as(u16, 0), rects[1].y);
    try std.testing.expectEqual(@as(u16, 50), rects[2].y);
}

test "grid layout — single node gets full screen" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    engine.workspaces[0].layout = .grid;

    const screen = Rect{ .x = 0, .y = 0, .width = 500, .height = 400 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expect(rects[0].eql(screen));
}

test "monocle — focus changes which node gets full screen" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try engine.workspaces[0].addNode(allocator, 1);
    try engine.workspaces[0].addNode(allocator, 2);
    engine.workspaces[0].layout = .monocle;

    const screen = Rect{ .x = 0, .y = 0, .width = 800, .height = 600 };

    // Focus on node 1 (index 0)
    engine.workspaces[0].active_index = 0;
    const rects1 = try engine.calculate(0, screen);
    defer allocator.free(rects1);
    try std.testing.expect(rects1[0].eql(screen));
    try std.testing.expect(rects1[1].eql(Rect.zero));

    // Focus on node 2 (index 1)
    engine.workspaces[0].active_index = 1;
    const rects2 = try engine.calculate(0, screen);
    defer allocator.free(rects2);
    try std.testing.expect(rects2[0].eql(Rect.zero));
    try std.testing.expect(rects2[1].eql(screen));
}

test "engine init — 9 workspaces with correct names" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(u8, 0), engine.active_workspace);

    for (engine.workspaces, 0..) |ws, i| {
        const expected_name = [_]u8{'1' + @as(u8, @intCast(i))};
        try std.testing.expect(std.mem.eql(u8, &expected_name, ws.name));
        try std.testing.expectEqual(@as(usize, 0), ws.node_ids.items.len);
        try std.testing.expectEqual(Layout.monocle, ws.layout);
    }
}

test "grid layout — five nodes (3x2 grid, last row sparse)" {
    const allocator = std.testing.allocator;
    var engine = LayoutEngine.init(allocator);
    defer engine.deinit();

    for (1..6) |id| {
        try engine.workspaces[0].addNode(allocator, @intCast(id));
    }
    engine.workspaces[0].layout = .grid;

    const screen = Rect{ .x = 0, .y = 0, .width = 900, .height = 600 };
    const rects = try engine.calculate(0, screen);
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 5), rects.len);

    // 3 cols, 2 rows. Cells: 300x300
    // Row 0: nodes 0,1,2
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 300), rects[1].x);
    try std.testing.expectEqual(@as(u16, 600), rects[2].x);

    // Row 1: nodes 3,4 (5th slot empty — but we still compute rects for existing nodes)
    try std.testing.expectEqual(@as(u16, 0), rects[3].x);
    try std.testing.expectEqual(@as(u16, 300), rects[3].y);
    try std.testing.expectEqual(@as(u16, 300), rects[4].x);
    try std.testing.expectEqual(@as(u16, 300), rects[4].y);
}
