const std = @import("std");
const builtin = @import("builtin");
const build_zon = @embedFile("build.zig.zon");

const default_target: std.Target.Query = switch (builtin.os.tag) {
    // Native Zig otherwise records the exact host macOS version as the
    // deployment floor. Keep local CLI builds and the non-notarized .app
    // usable on the oldest macOS version advertised by the bundle instead.
    .macos => .{
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
    },
    .linux => linux_default_target,
    else => .{},
};

// A native glibc build links the host's crt1.o, and toolchains from GCC 16 on
// emit a .sframe section into it whose R_X86_64_PC64 relocations Zig's ELF
// linker cannot process ("unhandled relocation type"). Naming the host glibc
// explicitly makes the query non-native, so Zig builds its own csu objects and
// libc stubs from the ones it ships and never opens the host crt1.o. The build
// stays host-compatible because the pinned version is the detected host one;
// `addNativeSystemPaths` below restores the search roots this costs us.
const linux_default_target: std.Target.Query = if (builtin.abi.isGnu()) .{
    .os_tag = .linux,
    .abi = .gnu,
    .glibc_version = builtin.target.os.version_range.linux.glibc,
} else .{};

fn packageVersion() []const u8 {
    const marker = ".version = \"";
    const start = (std.mem.indexOf(u8, build_zon, marker) orelse unreachable) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, build_zon, start, '"') orelse unreachable;
    return build_zon[start..end];
}

fn macosSdkPath(b: *std.Build) []const u8 {
    var exit_code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        &exit_code,
        .inherit,
    ) catch @panic("xcrun could not locate the macOS SDK");
    return std.mem.trim(u8, output, " \r\n\t");
}

fn addNativeSystemPaths(b: *std.Build, mod: *std.Build.Module) void {
    // Counterpart to the explicit glibc pin in `linux_default_target`: because
    // the query is no longer native, Zig stops probing the host for the X11 and
    // OpenGL headers and libraries raylib links against. Ask Zig for the same
    // roots a native query would have found rather than assuming an FHS layout,
    // so Nix-style hosts keep working.
    const paths = std.zig.system.NativePaths.detect(
        b.allocator,
        b.graph.io,
        &b.graph.host.result,
        &b.graph.environ_map,
    ) catch @panic("could not detect native system paths");
    // Detection offers the union of every layout it knows about, and Zig turns
    // each missing one into a warning that fails the compile, so drop the
    // directories this host does not actually have.
    for (paths.include_dirs.items) |dir| {
        if (dirExists(b, dir)) mod.addSystemIncludePath(.{ .cwd_relative = dir });
    }
    for (paths.lib_dirs.items) |dir| {
        if (dirExists(b, dir)) mod.addLibraryPath(.{ .cwd_relative = dir });
    }
    for (paths.rpaths.items) |dir| {
        if (dirExists(b, dir)) mod.addRPathSpecial(dir);
    }
}

fn dirExists(b: *std.Build, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(b.graph.io, path, .{}) catch return false;
    dir.close(b.graph.io);
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });

    const optimize = b.standardOptimizeOption(.{});
    const neovim_supported = switch (target.result.os.tag) {
        .linux, .macos => true,
        else => false,
    };
    // Keep the integration opt-in so packagers and users with unusual editor
    // setups can retain the dependency-free built-in editing path. A future
    // default change does not alter the compile boundary below.
    const enable_neovim = b.option(bool, "neovim", "Compile the embedded Neovim editor (Linux/macOS)") orelse false;
    if (enable_neovim and !neovim_supported) {
        @panic("-Dneovim=true is currently supported only on Linux and macOS");
    }

    // Only the pinned host build needs the host search roots back; a genuine
    // `-Dtarget=` cross build must not be handed this machine's headers.
    const native_linux = target.result.os.tag == .linux and
        target.result.os.tag == builtin.os.tag and
        target.result.cpu.arch == builtin.cpu.arch;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", packageVersion());
    build_options.addOption(bool, "neovim", enable_neovim);
    exe_mod.addOptions("build_options", build_options);

    var neovim_font_path: ?std.Build.LazyPath = null;
    var neovim_font_license_path: ?std.Build.LazyPath = null;
    var neovim_mpack_license_path: ?std.Build.LazyPath = null;

    const neovim_mod = b.createModule(.{
        .root_source_file = b.path(if (enable_neovim) "src/nvim/enabled.zig" else "src/nvim/stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (enable_neovim) true else null,
    });
    if (enable_neovim) {
        if (b.lazyDependency("mpack", .{})) |mpack_dep| {
            neovim_mpack_license_path = mpack_dep.path("LICENSE");
            neovim_mod.addIncludePath(mpack_dep.path("src/mpack"));
            neovim_mod.addCMacro("MPACK_EXTENSIONS", "1");
            neovim_mod.addCSourceFiles(.{
                .root = mpack_dep.path("src/mpack"),
                .files = &.{
                    "mpack-common.c",
                    "mpack-expect.c",
                    "mpack-node.c",
                    "mpack-platform.c",
                    "mpack-reader.c",
                    "mpack-writer.c",
                },
                .flags = &.{"-std=c99"},
            });
        }
        if (b.lazyDependency("jetbrains_mono", .{})) |font_dep| {
            neovim_font_path = font_dep.path("fonts/ttf/JetBrainsMono-Regular.ttf");
            neovim_font_license_path = font_dep.path("OFL.txt");
        }
    }
    build_options.addOption(
        []const u8,
        "neovim_font_development_path",
        if (neovim_font_path) |path| path.getPath(b) else "",
    );
    exe_mod.addImport("neovim", neovim_mod);

    exe_mod.addCSourceFile(.{ .file = b.path("src/pdf/pdfgen.c") });
    exe_mod.addIncludePath(b.path("src/pdf"));
    exe_mod.addCSourceFile(.{ .file = b.path("src/qr/qrcodegen.c") });
    exe_mod.addIncludePath(b.path("src/qr"));
    exe_mod.addCSourceFile(.{ .file = b.path("src/svg_rasterizer.c") });
    exe_mod.addIncludePath(b.path("src"));
    if (target.result.os.tag == .macos) {
        // An explicit deployment target makes Zig treat the otherwise-native
        // macOS build as a cross target, so provide the host SDK search roots
        // that a plain native query would discover implicitly.
        const sdk = macosSdkPath(b);
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        exe_mod.addCSourceFile(.{ .file = b.path("src/macos_open_documents.m") });
        exe_mod.linkFramework("AppKit", .{});
        exe_mod.linkFramework("Foundation", .{});
    } else if (target.result.os.tag == .windows) {
        exe_mod.linkSystemLibrary("iphlpapi", .{});
    } else if (native_linux) {
        addNativeSystemPaths(b, exe_mod);
    }

    const exe = b.addExecutable(.{
        .name = "rayslides",
        .root_module = exe_mod,
        // raylib-zig records its `-lGL -lX11 ...` dependencies as shared-object
        // members inside the static libraylib.a. LLD reports each one as
        // "neither ET_REL nor LLVM bitcode", and Zig escalates that unexpected
        // stderr into a build failure, so any LLD-linked build (ReleaseFast and
        // friends, which use the LLVM backend) breaks. Zig's own ELF linker
        // ignores those members, and the explicit glibc pin above already gave
        // it csu objects it can handle. The exe links the system libraries
        // directly regardless, so nothing is lost.
        .use_lld = if (native_linux) false else null,
    });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    raylib_artifact.root_module.addCMacro("SUPPORT_FILEFORMAT_JPG", "1");
    if (native_linux) addNativeSystemPaths(b, raylib_artifact.root_module);

    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    b.installArtifact(exe);
    if (enable_neovim) {
        const install_neovim_runtime = b.addInstallDirectory(.{
            .source_dir = b.path("src/nvim/runtime"),
            .install_dir = .prefix,
            .install_subdir = "share/rayslides/nvim",
        });
        b.getInstallStep().dependOn(&install_neovim_runtime.step);
        if (neovim_font_path) |font_path| {
            const install_neovim_font = b.addInstallFile(
                font_path,
                "share/rayslides/fonts/JetBrainsMono-Regular.ttf",
            );
            b.getInstallStep().dependOn(&install_neovim_font.step);
        }
        if (neovim_font_license_path) |license_path| {
            const install_neovim_font_license = b.addInstallFile(
                license_path,
                "share/rayslides/fonts/JetBrainsMono-OFL.txt",
            );
            b.getInstallStep().dependOn(&install_neovim_font_license.step);
        }
        if (neovim_mpack_license_path) |license_path| {
            const install_neovim_mpack_license = b.addInstallFile(
                license_path,
                "share/rayslides/licenses/MPack-LICENSE.txt",
            );
            b.getInstallStep().dependOn(&install_neovim_mpack_license.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const neovim_unit_tests = b.addTest(.{
        .root_module = neovim_mod,
    });
    const run_neovim_unit_tests = b.addRunArtifact(neovim_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_neovim_unit_tests.step);

    if (enable_neovim) {
        const neovim_probe_mod = b.createModule(.{
            .root_source_file = b.path("src/nvim/probe_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        neovim_probe_mod.addImport("neovim", neovim_mod);
        const neovim_probe = b.addExecutable(.{
            .name = "rayslides-neovim-probe",
            .root_module = neovim_probe_mod,
        });
        const run_neovim_probe = b.addRunArtifact(neovim_probe);
        const neovim_probe_step = b.step("neovim-probe", "Run the live Neovim embed protocol probe");
        neovim_probe_step.dependOn(&run_neovim_probe.step);
    }

    const neovim_runtime_test_cmd = b.addSystemCommand(&.{
        "nvim",
        "--clean",
        "--headless",
        "--cmd",
        "set runtimepath^=src/nvim/runtime",
        "-l",
        "tests/nvim_runtime_syntax.lua",
    });
    neovim_runtime_test_cmd.setCwd(b.path("."));
    const neovim_runtime_test_step = b.step("neovim-runtime-test", "Test the bundled .sld Neovim runtime");
    neovim_runtime_test_step.dependOn(&neovim_runtime_test_cmd.step);

    const baseline_self_test_cmd = b.addSystemCommand(&.{ "python3", "tools/studio_baseline.py", "self-test" });
    const baseline_self_test_step = b.step("studio-baseline-test", "Test the Studio visual/performance baseline harness");
    baseline_self_test_step.dependOn(&baseline_self_test_cmd.step);

    const baseline_check_cmd = b.addSystemCommand(&.{ "python3", "tools/studio_baseline.py", "check", "--binary" });
    baseline_check_cmd.addArtifactArg(exe);
    if (b.args) |args| baseline_check_cmd.addArgs(args);
    const baseline_check_step = b.step("studio-baselines", "Capture and compare opt-in Studio visual/performance baselines");
    baseline_check_step.dependOn(&baseline_check_cmd.step);

    const baseline_update_cmd = b.addSystemCommand(&.{ "python3", "tools/studio_baseline.py", "update", "--binary" });
    baseline_update_cmd.addArtifactArg(exe);
    if (b.args) |args| baseline_update_cmd.addArgs(args);
    const baseline_update_step = b.step("studio-baselines-update", "Capture and replace Studio visual/performance baselines");
    baseline_update_step.dependOn(&baseline_update_cmd.step);

    if (enable_neovim) {
        const neovim_baseline_check_cmd = b.addSystemCommand(&.{
            "python3",
            "tools/studio_baseline.py",
            "check",
            "--suite=neovim",
            "--binary",
        });
        neovim_baseline_check_cmd.addArtifactArg(exe);
        if (b.args) |args| neovim_baseline_check_cmd.addArgs(args);
        const neovim_baseline_check_step = b.step(
            "neovim-baselines",
            "Capture and compare the embedded Neovim overlay baselines",
        );
        neovim_baseline_check_step.dependOn(&neovim_baseline_check_cmd.step);

        const neovim_baseline_update_cmd = b.addSystemCommand(&.{
            "python3",
            "tools/studio_baseline.py",
            "update",
            "--suite=neovim",
            "--binary",
        });
        neovim_baseline_update_cmd.addArtifactArg(exe);
        if (b.args) |args| neovim_baseline_update_cmd.addArgs(args);
        const neovim_baseline_update_step = b.step(
            "neovim-baselines-update",
            "Capture and replace the embedded Neovim overlay baselines",
        );
        neovim_baseline_update_step.dependOn(&neovim_baseline_update_cmd.step);
    }

    const release_confidence_step = b.step("release-confidence", "Run headless release-resilience and baseline-harness tests");
    release_confidence_step.dependOn(test_step);
    release_confidence_step.dependOn(baseline_self_test_step);

    const macos_release_qa_step = b.step("macos-release-qa", "Run automated macOS Studio baseline gates; see docs/MACOS_RELEASE_QA.md");
    macos_release_qa_step.dependOn(baseline_check_step);

    if (target.result.os.tag == .macos) {
        const package_cmd = b.addSystemCommand(&.{"python3"});
        package_cmd.addFileArg(b.path("tools/package_macos_app.py"));
        package_cmd.addArg("--binary");
        package_cmd.addArtifactArg(exe);
        package_cmd.addArg("--output");
        const packaged_app = package_cmd.addOutputDirectoryArg("Rayslides.app");
        package_cmd.addArgs(&.{ "--version", packageVersion(), "--icon" });
        package_cmd.addFileArg(b.path("src/assets/rayslides-app-icon.png"));
        if (enable_neovim) {
            package_cmd.addArgs(&.{"--neovim-runtime"});
            package_cmd.addDirectoryArg(b.path("src/nvim/runtime"));
            if (neovim_font_path) |font_path| {
                package_cmd.addArgs(&.{"--neovim-font"});
                package_cmd.addFileArg(font_path);
            }
            if (neovim_font_license_path) |license_path| {
                package_cmd.addArgs(&.{"--neovim-font-license"});
                package_cmd.addFileArg(license_path);
            }
            if (neovim_mpack_license_path) |license_path| {
                package_cmd.addArgs(&.{"--neovim-mpack-license"});
                package_cmd.addFileArg(license_path);
            }
        }

        const install_app = b.addInstallDirectory(.{
            .source_dir = packaged_app,
            .install_dir = .prefix,
            .install_subdir = "Rayslides.app",
        });
        const macos_app_step = b.step("macos-app", "Build a non-notarized, double-clickable zig-out/Rayslides.app");
        macos_app_step.dependOn(&install_app.step);
    }
}
