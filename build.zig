const std = @import("std");

const package_name = "zig-router";
const package_path = "src/router.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const getty = b.dependency("getty", .{ .target = target, .optimize = optimize });

    const mod = b.addModule(package_name, .{
        .root_source_file = .{ .path = package_path },
        .imports = &.{
            .{ .name = "getty", .module = getty.module("getty") },
        },
    });

    const exe_test = b.addTest(.{
        .root_source_file = .{ .path = package_path },
        .target = target,
        .optimize = optimize,
    });
    exe_test.root_module.addImport("getty", getty.module("getty"));
    const run_test_exe = b.addRunArtifact(exe_test);
    const run_test = b.step("test", "Run unit tests");
    run_test.dependOn(&run_test_exe.step);

    const exe_example = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_example.root_module.addImport("zig-router", mod);
    const run_example_exe = b.addRunArtifact(exe_example);
    const run_example = b.step("example", "Run example");
    run_example.dependOn(&run_example_exe.step);

    const docs_step = b.step("docs", "Build the project documentation");

    const doc_obj = b.addObject(.{
        .name = "docs",
        .root_source_file = .{ .path = package_path },
        .target = target,
        .optimize = optimize,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = std.fmt.comptimePrint("docs/{s}", .{package_name}),
    });

    docs_step.dependOn(&install_docs.step);
}
