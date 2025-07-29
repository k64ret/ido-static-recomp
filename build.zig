const std = @import("std");

// 1. Build recomp binary
//    `make RELEASE=1 setup`
//    `make -C $(RABBITIZER) static CC=gcc CXX=g++ DEBUG=0`
// 2. Run the build script
//    `make RELEASE=1 VERSION=7.1`

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const setup_step = b.step("setup", "Build the recomp exe");

    const version = b.option(
        enum { @"5.3", @"7.1" },
        "version",
        "Version of IDO toolchain to recompile (default: 7.1)",
    ) orelse .@"7.1";
    _ = version;

    const ido_dep = b.dependency("upstream", .{});

    const rabbitizer_dep = b.dependency("rabbitizer", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    const rabbitizer_artifact = rabbitizer_dep.artifact("rabbitizerpp");

    const recomp_exe = b.addExecutable(.{
        .name = "recomp.elf",
        .target = target,
        .optimize = optimize,
    });

    recomp_exe.addIncludePath(rabbitizer_artifact.getEmittedIncludeTree());

    recomp_exe.addCSourceFile(.{
        .file = ido_dep.path("recomp.cpp"),
    });

    recomp_exe.linkLibrary(rabbitizer_artifact);

    const recomp_install_cmd = b.addInstallArtifact(recomp_exe, .{});
    b.getInstallStep().dependOn(&recomp_install_cmd.step);

    setup_step.dependOn(&recomp_install_cmd.step);
}
