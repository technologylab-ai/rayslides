const std = @import("std");
const builtin = @import("builtin");
const build_zon = @embedFile("build.zig.zon");

const default_target: std.Target.Query = if (builtin.os.tag == .macos) .{
    // Native Zig otherwise records the exact host macOS version as the
    // deployment floor. Keep local CLI builds and the non-notarized .app
    // usable on the oldest macOS version advertised by the bundle instead.
    .os_tag = .macos,
    .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", packageVersion());
    exe_mod.addOptions("build_options", build_options);

    exe_mod.addCSourceFile(.{ .file = b.path("src/pdf/pdfgen.c") });
    exe_mod.addIncludePath(b.path("src/pdf"));
    exe_mod.addCSourceFile(.{ .file = b.path("src/qr/qrcodegen.c") });
    exe_mod.addIncludePath(b.path("src/qr"));
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
    }

    const exe = b.addExecutable(.{
        .name = "rayslides",
        .root_module = exe_mod,
    });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    raylib_artifact.root_module.addCMacro("SUPPORT_FILEFORMAT_JPG", "1");

    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    b.installArtifact(exe);

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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

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

        const install_app = b.addInstallDirectory(.{
            .source_dir = packaged_app,
            .install_dir = .prefix,
            .install_subdir = "Rayslides.app",
        });
        const macos_app_step = b.step("macos-app", "Build a non-notarized, double-clickable zig-out/Rayslides.app");
        macos_app_step.dependOn(&install_app.step);
    }
}
