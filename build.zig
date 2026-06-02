const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addAnonymousImport("start_page_asset", .{
        .root_source_file = b.path("assets/start_page/start_page.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "nimlo",
        .root_module = root_module,
    });

    if (target.result.os.tag == .macos) {
        exe.root_module.linkSystemLibrary("c", .{});
        exe.root_module.linkSystemLibrary("objc", .{});
        exe.root_module.linkFramework("AppKit", .{});
        exe.root_module.linkFramework("WebKit", .{});
    }

    b.installArtifact(exe);

    if (target.result.os.tag == .macos) {
        const bundle_exe = b.addInstallFile(
            exe.getEmittedBin(),
            "Nimlo.app/Contents/MacOS/nimlo",
        );
        const bundle_plist = b.addInstallFile(
            b.path("macos/Info.plist"),
            "Nimlo.app/Contents/Info.plist",
        );

        b.getInstallStep().dependOn(&bundle_exe.step);
        b.getInstallStep().dependOn(&bundle_plist.step);

        const bundle_step = b.step("bundle", "Build Nimlo.app");
        bundle_step.dependOn(&bundle_exe.step);
        bundle_step.dependOn(&bundle_plist.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Nimlo");
    run_step.dependOn(&run_cmd.step);

    const url_input_tests = b.addTest(.{
        .name = "url-input-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/url_input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_url_input_tests = b.addRunArtifact(url_input_tests);
    const tab_tests = b.addTest(.{
        .name = "tab-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/tab.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tab_tests = b.addRunArtifact(tab_tests);
    const tab_manager_tests = b.addTest(.{
        .name = "tab-manager-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/tab_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tab_manager_tests = b.addRunArtifact(tab_manager_tests);
    const browser_tests = b.addTest(.{
        .name = "browser-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .macos) {
        browser_tests.root_module.linkSystemLibrary("c", .{});
        browser_tests.root_module.linkSystemLibrary("objc", .{});
        browser_tests.root_module.linkFramework("AppKit", .{});
        browser_tests.root_module.linkFramework("WebKit", .{});
    }
    const run_browser_tests = b.addRunArtifact(browser_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_url_input_tests.step);
    test_step.dependOn(&run_tab_tests.step);
    test_step.dependOn(&run_tab_manager_tests.step);
    test_step.dependOn(&run_browser_tests.step);
}
