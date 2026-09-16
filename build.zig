const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional substring filter for test builds. Zig applies `--test-filter` at
    // compile time, so a filtered test binary contains only the matching tests.
    // Used by the VS Code "Debug: unit tests (filtered)" launch configuration.
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Only build tests whose name contains this substring",
    ) orelse "";
    const filters: []const []const u8 = if (test_filter.len > 0) &.{test_filter} else &.{};

    // The library is the whole point: `src/lib.zig` re-exports the public API.
    // Everything under src/ is reachable from it via @import.
    const lib_mod = b.addModule("leveldb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------------------------------------------------------------
    // CLI executable
    // ------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "leveldb-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "leveldb", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the leveldb-zig CLI");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------
    // Unit tests (colocated `test` blocks under src/)
    // ------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // ------------------------------------------------------------------
    // Integration tests (tests/)
    // ------------------------------------------------------------------
    const integration_tests = b.addTest(.{
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "leveldb", .module = lib_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // ------------------------------------------------------------------
    // Debuggable test binaries
    //
    // `zig build test` compiles and runs in one step, which makes it awkward to
    // attach a debugger. This step builds the test executables without running
    // them and installs them at predictable paths so lldb / VS Code can launch
    // them directly.
    //
    //   zig build test-bin
    //   zig-out/bin/leveldb-zig-tests
    //   zig-out/bin/leveldb-zig-integration-tests
    // ------------------------------------------------------------------
    const install_unit_bin = b.addInstallBinFile(unit_tests.getEmittedBin(), "leveldb-zig-tests");
    const install_integration_bin = b.addInstallBinFile(
        integration_tests.getEmittedBin(),
        "leveldb-zig-integration-tests",
    );
    const test_bin_step = b.step("test-bin", "Build test executables for debugging");
    test_bin_step.dependOn(&install_unit_bin.step);
    test_bin_step.dependOn(&install_integration_bin.step);

    // `zig build fmt` and `zig build fmt-check` keep style honest.
    const fmt = b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" } });
    b.step("fmt", "Format all Zig sources").dependOn(&fmt.step);
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "tests", "build.zig" }, .check = true });
    b.step("fmt-check", "Check formatting").dependOn(&fmt_check.step);
}
