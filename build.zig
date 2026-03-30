const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── libteru (core library, C-ABI compatible) ──────────────────────
    // Tests and library do NOT link GPU/font libs — only pure Zig logic.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "teru",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // ── teru executable (links GPU + font + windowing libs) ──────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // System libraries for the windowed terminal
    const gpu_libs = [_][]const u8{
        "GL",         // OpenGL
        "EGL",        // EGL context creation
        "xcb",        // X11 via XCB
        "X11",        // Xlib (for XOpenDisplay, XGetXCBConnection)
        "X11-xcb",    // Xlib-XCB bridge
        "freetype2",  // Font rasterization
        "fontconfig",  // System font discovery
    };
    for (gpu_libs) |lib_name| {
        exe_mod.linkSystemLibrary(lib_name, .{});
    }

    const exe = b.addExecutable(.{
        .name = "teru",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ── run step ─────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run teru terminal");
    run_step.dependOn(&run_cmd.step);

    // ── tests (pure Zig, no GPU libs needed) ─────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
