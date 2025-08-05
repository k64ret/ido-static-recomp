const std = @import("std");

fn captureStdOutCFile(run: *std.Build.Step.Run) std.Build.LazyPath {
    std.debug.assert(run.stdio != .inherit);

    if (run.captured_stdout) |output| return .{ .generated = .{ .file = &output.generated_file } };

    const output = run.step.owner.allocator.create(std.Build.Step.Run.Output) catch @panic("OOM");
    output.* = .{
        .prefix = "",
        .basename = "stdout.c",
        .generated_file = .{ .step = &run.step },
    };
    run.captured_stdout = output;
    return .{ .generated = .{ .file = &output.generated_file } };
}

// 1. Build recomp binary
//    `make RELEASE=1 setup`
//    `make -C $(RABBITIZER) static CC=gcc CXX=g++ DEBUG=0`
// 2. Run the build script
//    `make RELEASE=1 VERSION=7.1`

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const recomp_step = b.step("recomp", "Run the `recomp.elf` executable");

    const version = b.option(
        enum { @"5.3", @"7.1" },
        "version",
        "Version of IDO toolchain to recompile (default: 7.1)",
    ) orelse .@"7.1";
    const werror = b.option(
        bool,
        "werror",
        "Treat warnings as errors (default: false)",
    ) orelse false;
    _ = werror;
    const asan = b.option(
        bool,
        "asan",
        "Enable address and undefined behavior sanitizers (default: false)",
    ) orelse false;
    _ = asan;

    const ido_version_str: []const u8 = switch (version) {
        .@"5.3" => "53",
        .@"7.1" => "71",
    };
    const ido_version_macro = b.fmt("IDO{s}", .{ido_version_str});

    const ido_dep = b.dependency("upstream", .{});

    const ido_root = ido_dep.path(".");
    const irix_root = ido_dep.path("ido");
    const irix_usr_dir = irix_root.path(b, b.fmt("{s}/usr", .{@tagName(version)}));

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

    // std.debug.print("Rabbitizer include directory: {s}\nNew line starts here...\n", .{rabbitizer_artifact.getEmittedIncludeTree().getDisplayName()});
    recomp_exe.addIncludePath(rabbitizer_artifact.getEmittedIncludeTree());

    recomp_exe.addCSourceFile(.{
        .file = ido_dep.path("recomp.cpp"),
    });

    recomp_exe.linkLibrary(rabbitizer_artifact);

    const recomp_install_cmd = b.addInstallArtifact(recomp_exe, .{});
    b.getInstallStep().dependOn(&recomp_install_cmd.step);

    const recomp_cmd = b.addRunArtifact(recomp_exe);
    recomp_cmd.step.dependOn(&recomp_install_cmd.step);

    if (b.args) |args| recomp_cmd.addArgs(args);

    recomp_step.dependOn(&recomp_cmd.step);

    const libc_impl_53_obj = b.addObject(.{
        .name = "libc_impl_53",
        .link_libc = true,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    libc_impl_53_obj.addIncludePath(ido_root);

    libc_impl_53_obj.addCSourceFile(.{
        .file = ido_root.path(b, "libc_impl.c"),
        .flags = &.{
            "-std=c11",
            "-Os",
            "-fno-strict-aliasing",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-Wshadow",
            "-Wno-unused-parameter",
            "-Wno-deprecated-declarations",
        },
    });

    libc_impl_53_obj.root_module.addCMacro("IDO53", "");

    const libc_impl_71_obj = b.addObject(.{
        .name = "libc_impl_71",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    libc_impl_71_obj.addIncludePath(ido_root);

    libc_impl_71_obj.addCSourceFile(.{
        .file = ido_root.path(b, "libc_impl.c"),
        .flags = &.{
            "-std=c11",
            "-Os",
            "-fno-strict-aliasing",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-Wshadow",
            "-Wno-unused-parameter",
            "-Wno-deprecated-declarations",
        },
    });

    libc_impl_71_obj.root_module.addCMacro("IDO71", "");

    const version_info_obj = b.addObject(.{
        .name = "version_info",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    version_info_obj.addIncludePath(ido_root);

    version_info_obj.addCSourceFile(.{
        .file = ido_root.path(b, "version_info.c"),
        .flags = &.{
            "-std=c11",
            "-Os",
            "-fno-strict-aliasing",
        },
    });
    // version_info_obj.setVerboseCC(true);

    // FIXME these macros shouldn't be hardcoded
    version_info_obj.root_module.addCMacro("PACKAGE_VERSION", "\"v1.2-17-gd5aec59\"");
    version_info_obj.root_module.addCMacro("DATETIME", "\"2025-07-25 23:02:45 UTC-0400\"");
    version_info_obj.root_module.addCMacro(ido_version_macro, "");

    // Rebuild version info if the recomp binary or libc_impl are updated
    version_info_obj.step.dependOn(&recomp_exe.step);
    version_info_obj.step.dependOn(&libc_impl_53_obj.step);
    version_info_obj.step.dependOn(&libc_impl_71_obj.step);

    // recomp_cmd.addFileArg(irix_usr_dir.path(b, "bin/cc"));
    // const gen_cc_src = captureStdOutCFile(recomp_cmd);
    // const gen_cc_src = b.addInstallFile(
    //     recomp_cmd.captureStdOut(),
    //     b.fmt("{s}/cc.c", .{@tagName(version)}),
    // );
    // const gen_cc_src = recomp_cmd.captureStdOut();

    // const cc_exe = b.addExecutable(.{
    //     .name = "cc",
    //     .target = target,
    //     .optimize = optimize,
    // });

    // cc_exe.addIncludePath(ido_root);

    // cc_exe.addObject(version_info_obj);
    // cc_exe.addObject(libc_impl_71_obj);

    // cc_exe.addCSourceFile(.{
    //     .file = gen_cc_src,
    //     .flags = &.{
    //         "-std=c11",
    //         "-Os",
    //         "-fno-strict-aliasing",
    //     },
    // });

    // b.installArtifact(cc_exe);

    _ = addInstallIdoBin(b, .{
        .name = "cc",
        .target = target,
        .optimize = optimize,
        .recomp = recomp_exe,
        .recomp_install = &recomp_install_cmd.step,
        .bin = irix_usr_dir.path(b, "bin/cc"),
        .include = ido_root,
        .objects = &.{ version_info_obj, libc_impl_71_obj },
    });
}

fn addLibcImplObject(b: *std.Build) void {}

const IdoBin = struct {
    name: []const u8,
    target: ?std.Build.ResolvedTarget = null,
    optimize: std.builtin.OptimizeMode = .Debug,
    recomp: *std.Build.Step.Compile,
    recomp_install: *std.Build.Step,
    bin: std.Build.LazyPath,
    include: std.Build.LazyPath,
    objects: []const *std.Build.Step.Compile,
};

fn addInstallIdoBin(b: *std.Build, source: IdoBin) *std.Build.Step.Compile {
    const recomp_cmd = b.addRunArtifact(source.recomp);
    recomp_cmd.step.dependOn(source.recomp_install);

    recomp_cmd.addFileArg(source.bin);
    const gen_src = captureStdOutCFile(recomp_cmd);

    const exe = b.addExecutable(.{
        .name = source.name,
        .target = source.target,
        .optimize = source.optimize,
    });

    exe.addIncludePath(source.include);

    for (source.objects) |obj| exe.addObject(obj);

    exe.addCSourceFile(.{
        .file = gen_src,
        .flags = &.{
            "-std=c11",
            "-Os",
            "-fno-strict-aliasing",
        },
    });

    b.installArtifact(exe);

    return exe;
}

const ido_71_tc = [_][]const u8{
    // `copt` currently does not build
    "cc",
    "acpp",
    "as0",
    "as1",
    "cfe",
    "ugen",
    "ujoin",
    "uld",
    "umerge",
    "uopt",
    "usplit",
    "upas",
    "edgcpfe",
    "NCC",
};

const ido_71_libs = [_][]const u8{
    "",
};

const ido_53_tc = [_][]const u8{
    "cc",
    "strip",
    "acpp",
    "as0",
    "as1",
    "cfe",
    "copt",
    "ugen",
    "ujoin",
    "uld",
    "umerge",
    "uopt",
    "usplit",
    "ld",
    "upas",
    "c++filt",
};

const ido_53_libs = [_][]const u8{
    "crt1.o",
    "crtn.o",
    "libc.so",
    "libc.so.1",
    "libexc.so",
    "libgen.so",
    "libm.so",
};
