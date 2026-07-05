const std = @import("std");

pub fn build(b: *std.Build) void {
    const macos_15_apple_silicon = std.Build.parseTargetQuery(.{
        .arch_os_abi = "aarch64-macos.15.0",
    }) catch unreachable;
    const target = b.standardTargetOptions(.{
        .default_target = macos_15_apple_silicon,
    });
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag == .macos and b.sysroot == null) {
        const sdk_path_output = b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" });
        b.sysroot = b.dupe(std.mem.trim(u8, sdk_path_output, " \t\r\n"));
    }

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addMacosSdkPaths(b, root_module, target);
    root_module.addAnonymousImport("start_page_asset", .{
        .root_source_file = b.path("assets/start_page/start_page.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addAnonymousImport("about_page_asset", .{
        .root_source_file = b.path("assets/about_page/about_page.zig"),
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
        const generated_icon = b.addSystemCommand(&.{
            "iconutil",
            "-c",
            "icns",
            b.path("macos/Nimlo.iconset").getPath(b),
            "-o",
            b.getInstallPath(.prefix, "Nimlo.app/Contents/Resources/Nimlo.icns"),
        });
        generated_icon.step.dependOn(&bundle_exe.step);
        generated_icon.step.dependOn(&bundle_plist.step);

        b.getInstallStep().dependOn(&bundle_exe.step);
        b.getInstallStep().dependOn(&bundle_plist.step);
        b.getInstallStep().dependOn(&generated_icon.step);

        const sign_bundle = b.addSystemCommand(&.{
            "codesign",
            "--force",
            "--sign",
            "-",
            b.getInstallPath(.prefix, "Nimlo.app"),
        });
        sign_bundle.step.dependOn(&bundle_exe.step);
        sign_bundle.step.dependOn(&bundle_plist.step);
        sign_bundle.step.dependOn(&generated_icon.step);
        b.getInstallStep().dependOn(&sign_bundle.step);

        const bundle_step = b.step("bundle", "Build Nimlo.app");
        bundle_step.dependOn(&sign_bundle.step);
    }

    const run_step = b.step("run", "Run Nimlo");
    if (target.result.os.tag == .macos) {
        const open_cmd = b.addSystemCommand(&.{
            "open",
            "-n",
            b.getInstallPath(.prefix, "Nimlo.app"),
        });
        open_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            open_cmd.addArg("--args");
            open_cmd.addArgs(args);
        }
        run_step.dependOn(&open_cmd.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        run_step.dependOn(&run_cmd.step);
    }

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
    const history_tests = b.addTest(.{
        .name = "history-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/history.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_history_tests = b.addRunArtifact(history_tests);
    const bookmarks_tests = b.addTest(.{
        .name = "bookmarks-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/bookmarks.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bookmarks_tests = b.addRunArtifact(bookmarks_tests);
    const downloads_tests = b.addTest(.{
        .name = "downloads-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/downloads.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_downloads_tests = b.addRunArtifact(downloads_tests);
    const history_page_tests = b.addTest(.{
        .name = "history-page-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/history_page_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_history_page_tests = b.addRunArtifact(history_page_tests);
    const bookmarks_page_tests = b.addTest(.{
        .name = "bookmarks-page-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bookmarks_page_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bookmarks_page_tests = b.addRunArtifact(bookmarks_page_tests);
    const downloads_page_tests = b.addTest(.{
        .name = "downloads-page-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/downloads_page_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_downloads_page_tests = b.addRunArtifact(downloads_page_tests);
    const browser_tests = b.addTest(.{
        .name = "browser-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addMacosSdkPaths(b, browser_tests.root_module, target);
    browser_tests.root_module.addAnonymousImport("start_page_asset", .{
        .root_source_file = b.path("assets/start_page/start_page.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_tests.root_module.addAnonymousImport("about_page_asset", .{
        .root_source_file = b.path("assets/about_page/about_page.zig"),
        .target = target,
        .optimize = optimize,
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
    test_step.dependOn(&run_bookmarks_tests.step);
    test_step.dependOn(&run_bookmarks_page_tests.step);
    test_step.dependOn(&run_downloads_tests.step);
    test_step.dependOn(&run_downloads_page_tests.step);
    test_step.dependOn(&run_history_tests.step);
    test_step.dependOn(&run_history_page_tests.step);
    test_step.dependOn(&run_browser_tests.step);
}

fn addMacosSdkPaths(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    const sysroot = b.sysroot orelse return;
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
}
