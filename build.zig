const std = @import("std");
const mach_core = @import("mach_core");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mach_core_dep = b.dependency("mach_core", .{
        .target = target,
        .optimize = optimize,
    });
    const app = try mach_core.App.init(b, mach_core_dep.builder, .{
        .name = "MSDF",
        .src = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &[_]std.Build.Module.Import{
            .{
                .name = "mach",
                .module = b.dependency("mach", .{
                    .target = target,
                    .optimize = optimize,
                }).module("mach"),
            },
            .{
                .name = "zigimg",
                .module = b.dependency("zigimg", .{}).module("zigimg"),
            },
        },
    });

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&app.run.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
