const std = @import("std");

pub const Package = struct {
    llvm_wrap: *std.Build.Module,
    llvm_wrap_c: *std.Build.Step.Compile,
    lib_paths: []const []const u8,

    pub fn link(pkg: Package, exe: *std.Build.Step.Compile) void {
        exe.linkLibrary(pkg.llvm_wrap_c);
        for (pkg.lib_paths) |path| {
            exe.addLibraryPath(.{ .path = path });
        }
        // exe.linkSystemLibrary();
        exe.root_module.addImport("llvm_wrap", pkg.llvm_wrap);
    }
};

pub fn package(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    _: struct {},
) !Package {
    const llvm_wrap = b.addModule("llvm_wrap", .{
        .root_source_file = .{ .path = thisDir() ++ "/src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const llvm_wrap_c = b.addStaticLibrary(.{
        .name = "llvm_wrap",
        .target = target,
        .optimize = optimize,
    });

    var llvm_args = std.ArrayList([]const u8).init(b.allocator);
    // const link_dynamic: bool = true;

    // zbullet_c_cpp.addIncludePath(.{ .path = thisDir() ++ "/libs/cbullet" });
    llvm_wrap_c.addIncludePath(.{ .path = thisDir() ++ "/src" });
    llvm_wrap.addIncludePath(.{ .path = thisDir() ++ "/src" });

    llvm_wrap_c.linkLibC();
    llvm_wrap_c.linkLibCpp();
    {
        const llvm_libs = b.run(&.{ "llvm-config", "--ldflags" });
        var lib_iter = std.mem.splitScalar(u8, llvm_libs, ' ');
        while (lib_iter.next()) |v| {
            if (std.mem.startsWith(u8, v, "-L")) {
                llvm_wrap_c.addLibraryPath(.{ .path = v[2..] });
                try llvm_args.append(v[2..]);
            }
        }
    }

    {
        const llvm_libs = b.run(&.{ "llvm-config", "--libnames", "--libs", "core" });
        var lib_iter = std.mem.splitScalar(u8, llvm_libs, ' ');
        while (lib_iter.next()) |v| {
            var name = v;
            if (std.mem.startsWith(u8, name, "lib")) {
                name = std.mem.trim(u8, v[3..], &std.ascii.whitespace);
            }
            if (std.mem.endsWith(u8, name, ".dylib")) {
                name = std.mem.trim(u8, name[0 .. name.len - 6], &std.ascii.whitespace);
            }

            llvm_wrap_c.linkSystemLibrary(name);
        }
    }

    const lib_paths = b.dupeStrings(llvm_args.items);

    llvm_args.items.len = 0;
    const llvm_libs = b.run(&.{ "llvm-config", "--cflags" });
    var lib_iter = std.mem.splitScalar(u8, std.mem.trim(u8, llvm_libs, &std.ascii.whitespace), ' ');
    while (lib_iter.next()) |v| {
        if (std.mem.startsWith(u8, v, "-I")) {
            llvm_wrap.addIncludePath(.{ .path = v[2..] });
            llvm_wrap_c.addIncludePath(.{ .path = v[2..] });
        }
    }

    // TODO: Use the old damping method for now otherwise there is a hang in powf().
    llvm_wrap_c.addCSourceFiles(.{
        .files = &.{
            thisDir() ++ "/src/llvm_wrap.cpp",
        },
        .flags = llvm_args.items,
    });

    return .{
        .llvm_wrap = llvm_wrap,
        .llvm_wrap_c = llvm_wrap_c,
        .lib_paths = lib_paths,
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "llvm_wrap",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "llvm_wrap",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
