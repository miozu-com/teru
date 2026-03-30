const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── libteru (core library, pure Zig, no system deps) ─────────────
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

    // ── teru executable ──────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Single system dependency: xcb (X11 protocol)
    exe_mod.linkSystemLibrary("xcb", .{});

    // Embedded: stb_truetype (compiled from vendored source)
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/stb_truetype.c"),
        .flags = &.{"-DSTB_TRUETYPE_IMPLEMENTATION"},
    });
    exe_mod.addIncludePath(b.path("vendor"));

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

    // ── tests (pure Zig, no system deps needed) ──────────────────────
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
