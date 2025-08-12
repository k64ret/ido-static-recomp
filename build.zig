const std = @import("std");

// 1. Build recomp binary
//    `make RELEASE=1 setup`
//    `make -C $(RABBITIZER) static CC=gcc CXX=g++ DEBUG=0`
// 2. Run the build script
//    `make RELEASE=1 VERSION=7.1`

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var bins: std.BoundedArray([]const u8, 16) = .{};
    var recomp_exe_flags: std.BoundedArray([]const u8, 32) = .{};
    var libc_impl_flags: std.BoundedArray([]const u8, 32) = .{};

    const recomp_step = b.step("recomp", "Build and run `recomp`");

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
    const full_traceback = b.option(
        bool,
        "full-traceback",
        "Full traceback, including names not exported (default: false)",
    ) orelse false;
    const trace = b.option(bool, "trace", "(default: false)") orelse false;
    const dump_instructions = b.option(
        bool,
        "dump-instructions",
        "Dump actual disassembly when dumping C code (default: false)",
    ) orelse false;

    switch (version) {
        .@"5.3" => bins.appendSliceAssumeCapacity(&ido_53_tc),
        .@"7.1" => bins.appendSliceAssumeCapacity(&ido_71_tc),
    }

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
        .name = "recomp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });

    if (full_traceback) {
        recomp_exe.root_module.addCMacro("FULL_TRACEBACK", "1");
    }

    if (trace) {
        recomp_exe.root_module.addCMacro("TRACE", "1");
    }

    if (dump_instructions) {
        recomp_exe.root_module.addCMacro("DUMP_INSTRUCTIONS", "1");
    }

    recomp_exe.addIncludePath(rabbitizer_artifact.getEmittedIncludeTree());

    recomp_exe_flags.appendSliceAssumeCapacity(&cpp_flags);
    recomp_exe_flags.appendSliceAssumeCapacity(&warnings);

    recomp_exe_flags.appendSliceAssumeCapacity(switch (optimize) {
        .Debug => &debug_opt_flags,
        else => &release_opt_flags,
    });

    if (asan) {
        recomp_exe_flags.appendSliceAssumeCapacity(&asan_flags);
    }

    switch (target.result.os.tag) {
        .freebsd => {
            recomp_exe.linkSystemLibrary("execinfo");
        },
        .linux => {
            recomp_exe_flags.appendAssumeCapacity("-Wl,-export-dynamic");
        },
        .windows => {
            recomp_exe_flags.appendAssumeCapacity("-static");
            recomp_exe.linkSystemLibrary("dl");
        },
        else => {},
    }

    recomp_exe.addCSourceFile(.{
        .file = ido_dep.path("recomp.cpp"),
        .flags = recomp_exe_flags.constSlice(),
    });

    recomp_exe.linkLibrary(rabbitizer_artifact);
    recomp_exe.linkSystemLibrary("m");

    const recomp_install_cmd = b.addInstallArtifact(recomp_exe, .{});
    b.getInstallStep().dependOn(&recomp_install_cmd.step);

    const recomp_run = b.addRunArtifact(recomp_exe);
    recomp_run.step.dependOn(&recomp_install_cmd.step);

    if (b.args) |args| recomp_run.addArgs(args);

    recomp_step.dependOn(&recomp_run.step);

    libc_impl_flags.appendSliceAssumeCapacity(&c_flags);
    libc_impl_flags.appendSliceAssumeCapacity(&warnings);
    libc_impl_flags.appendSliceAssumeCapacity(&.{
        "-Wno-unused-parameter",
        "-Wno-deprecated-declarations",
    });

    libc_impl_flags.appendSliceAssumeCapacity(switch (optimize) {
        .Debug => &debug_opt_flags,
        else => &release_opt_flags,
    });

    const libc_impl_53_obj = b.addObject(.{
        .name = "libc_impl_53",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    libc_impl_53_obj.addIncludePath(ido_root);

    libc_impl_53_obj.addCSourceFile(.{
        .file = ido_root.path(b, "libc_impl.c"),
        .flags = libc_impl_flags.constSlice(),
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
        .flags = libc_impl_flags.constSlice(),
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

    b.installDirectory(.{
        .source_dir = irix_usr_dir.path(b, "lib"),
        .install_dir = .bin,
        .install_subdir = "",
        .include_extensions = &.{
            ".cc",
            // ".o",
            // ".so",
            // ".so.1",
        },
    });

    for (bins.constSlice()) |bin| {
        const recomp_cmd = b.addRunArtifact(recomp_exe);
        recomp_cmd.step.dependOn(&recomp_install_cmd.step);

        recomp_cmd.addFileArg(irix_usr_dir.path(b, bin));
        recomp_cmd.max_stdio_size = 12 * 1024 * 1024; // 12 MiB

        var it = std.mem.splitBackwardsScalar(u8, bin, '/');
        const name = it.first();

        const write_files = b.addWriteFiles();
        const gen_src = write_files.addCopyFile(
            recomp_cmd.captureStdOut(),
            b.fmt("{s}.c", .{name}),
        );

        const run_step = b.step(
            name,
            b.fmt("Build and run `{s}`", .{name}),
        );

        const ido_bin = addInstallIdoBin(b, .{
            .name = name,
            .target = target,
            .optimize = optimize,
            .c_file = gen_src,
            .include = ido_root,
            .objects = &.{
                version_info_obj,
                switch (version) {
                    .@"5.3" => libc_impl_53_obj,
                    .@"7.1" => if (std.mem.eql(u8, name, "edgcpfe"))
                        libc_impl_53_obj
                    else
                        libc_impl_71_obj,
                },
            },
        });

        const run_cmd = b.addRunArtifact(ido_bin);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| run_cmd.addArgs(args);

        run_step.dependOn(&run_cmd.step);
    }
}

const IdoBin = struct {
    name: []const u8,
    target: ?std.Build.ResolvedTarget = null,
    optimize: std.builtin.OptimizeMode = .Debug,
    c_file: std.Build.LazyPath,
    include: std.Build.LazyPath,
    objects: []const *std.Build.Step.Compile,
};

fn addInstallIdoBin(b: *std.Build, source: IdoBin) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = source.name,
        .root_module = b.createModule(.{
            .target = source.target,
            .optimize = source.optimize,
            .strip = true,
        }),
    });

    exe.addIncludePath(source.include);

    exe.addCSourceFile(.{
        .file = source.c_file,
        .flags = &.{
            // "-std=c11",
            "-std=gnu11",
            "-Os",
            "-fno-strict-aliasing",
        },
    });

    for (source.objects) |o| exe.addObject(o);

    exe.linkSystemLibrary("m");

    const install_bin_cmd = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_bin_cmd.step);

    return exe;
}

const ido_71_tc = [_][]const u8{
    // `copt` currently does not build
    "bin/cc",
    "lib/acpp",
    "lib/as0",
    "lib/as1",
    "lib/cfe",
    "lib/ugen",
    "lib/ujoin",
    "lib/uld",
    "lib/umerge",
    "lib/uopt",
    "lib/usplit",
    "lib/upas",
    "lib/DCC/edgcpfe",
    // "NCC",
};

const ido_71_libs = [_][]const u8{
    "",
};

const ido_53_tc = [_][]const u8{
    "bin/cc",
    "bin/strip",
    "lib/acpp",
    "lib/as0",
    "lib/as1",
    "lib/cfe",
    "lib/copt",
    "lib/ugen",
    "lib/ujoin",
    "lib/uld",
    "lib/umerge",
    "lib/uopt",
    "lib/usplit",
    "lib/ld",
    "lib/upas",
    "lib/c++/c++filt",
};

const ido_53_libs = [_][]const u8{
    "lib/crt1.o",
    "lib/crtn.o",
    "lib/libc.so",
    "lib/libc.so.1",
    "lib/libexc.so",
    "lib/libgen.so",
    "lib/libm.so",
};

const asan_flags = [_][]const u8{
    "-fsanitize=address",
    "-fsanitize=pointer-compare",
    "-fsanitize=pointer-subtract",
    "-fsanitize=undefined",
    "-fno-sanitize-recover=all",
};

const debug_opt_flags = [_][]const u8{
    "-O0",
    "-ggdb3",
};

const release_opt_flags = [_][]const u8{
    "-Os",
};

const c_flags = [_][]const u8{
    "-std=c11",
    "-fno-strict-aliasing",
};

const warnings = [_][]const u8{
    "-Wall",
    "-Wextra",
    "-Wpedantic",
    "-Wshadow",
};

const cpp_flags = [_][]const u8{
    "-std=c++17",
};
