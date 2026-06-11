const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module with libc linking
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link SQLite3 system library
    root_module.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "prozig",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the prozig tracker");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_root_module.linkSystemLibrary("sqlite3", .{});

    const lib_tests = b.addTest(.{
        .root_module = test_root_module,
    });

    const run_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
