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

    const root_module = createNimloModule(b, target, optimize);
    addMacosSdkPaths(b, root_module, target);

    const exe = b.addExecutable(.{
        .name = "nimlo",
        .root_module = root_module,
    });

    if (target.result.os.tag == .macos) {
        exe.root_module.linkSystemLibrary("c", .{});
        exe.root_module.linkSystemLibrary("objc", .{});
        exe.root_module.linkFramework("AppKit", .{});
        exe.root_module.linkFramework("WebKit", .{});
    } else if (target.result.os.tag == .windows) {
        addWindowsSystemLibraries(exe.root_module);
    }

    b.installArtifact(exe);

    if (target.result.os.tag == .windows) {
        // The vendored loader must sit next to nimlo.exe; it is resolved at
        // runtime with LoadLibraryW (see src/webview/webview_win32.zig).
        const install_loader = b.addInstallBinFile(
            b.path(webview2LoaderSourcePath(target.result.cpu.arch)),
            "WebView2Loader.dll",
        );
        b.getInstallStep().dependOn(&install_loader.step);
    }

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
    const web_strings_tests = b.addTest(.{
        .name = "web-strings-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/web_strings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_web_strings_tests = b.addRunArtifact(web_strings_tests);
    const tab_strip_layout_tests = b.addTest(.{
        .name = "tab-strip-layout-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/tab_strip_layout.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tab_strip_layout_tests = b.addRunArtifact(tab_strip_layout_tests);
    const tab_drag_logic_tests = b.addTest(.{
        .name = "tab-drag-logic-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tab_drag_logic_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tab_drag_logic_tests = b.addRunArtifact(tab_drag_logic_tests);
    const internal_routes_tests = b.addTest(.{
        .name = "internal-routes-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/internal_routes_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_internal_routes_tests = b.addRunArtifact(internal_routes_tests);
    const abp_parser_tests = b.addTest(.{
        .name = "abp-parser-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blocking/abp_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_abp_parser_tests = b.addRunArtifact(abp_parser_tests);
    const blocking_matcher_tests = b.addTest(.{
        .name = "blocking-matcher-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blocking/matcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_blocking_matcher_tests = b.addRunArtifact(blocking_matcher_tests);
    const webkit_rules_tests = b.addTest(.{
        .name = "webkit-rules-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blocking/webkit_rules.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_webkit_rules_tests = b.addRunArtifact(webkit_rules_tests);
    const filter_lists_tests = b.addTest(.{
        .name = "filter-lists-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/filter_lists.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_filter_lists_tests = b.addRunArtifact(filter_lists_tests);
    const list_update_tests = b.addTest(.{
        .name = "list-update-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/list_update_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_list_update_tests = b.addRunArtifact(list_update_tests);
    const webview2_tests = b.addTest(.{
        .name = "webview2-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/webview/webview2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_webview2_tests = b.addRunArtifact(webview2_tests);
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

    // Cross-compiles the stub configuration so platform-specific code leaking
    // into shared modules fails fast: `zig build check-portable`. Linux is the
    // stub target now that Windows compiles the real Win32/WebView2 code.
    const portable_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const portable_module = createNimloModule(b, portable_target, optimize);
    portable_module.link_libc = true;
    const portable_exe = b.addExecutable(.{
        .name = "nimlo-portable-check",
        .root_module = portable_module,
    });
    const check_portable_step = b.step("check-portable", "Compile for a stub (non-macOS, non-Windows) target to catch platform leaks in shared code");
    check_portable_step.dependOn(&portable_exe.step);

    // Cross-compiles and links the real Windows configuration from any host:
    // `zig build check-windows`. This is the compile-time guard for the Win32
    // port while development happens on macOS.
    const check_windows_step = b.step("check-windows", "Cross-compile and link the Win32/WebView2 configuration");
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const windows_target = b.resolveTargetQuery(.{
            .cpu_arch = arch,
            .os_tag = .windows,
        });
        const windows_module = createNimloModule(b, windows_target, optimize);
        addWindowsSystemLibraries(windows_module);
        const windows_exe = b.addExecutable(.{
            .name = b.fmt("nimlo-windows-check-{s}", .{@tagName(arch)}),
            .root_module = windows_module,
        });
        check_windows_step.dependOn(&windows_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_url_input_tests.step);
    test_step.dependOn(&run_tab_tests.step);
    test_step.dependOn(&run_tab_manager_tests.step);
    test_step.dependOn(&run_bookmarks_tests.step);
    test_step.dependOn(&run_bookmarks_page_tests.step);
    test_step.dependOn(&run_web_strings_tests.step);
    test_step.dependOn(&run_tab_strip_layout_tests.step);
    test_step.dependOn(&run_tab_drag_logic_tests.step);
    test_step.dependOn(&run_internal_routes_tests.step);
    test_step.dependOn(&run_abp_parser_tests.step);
    test_step.dependOn(&run_blocking_matcher_tests.step);
    test_step.dependOn(&run_webkit_rules_tests.step);
    test_step.dependOn(&run_filter_lists_tests.step);
    test_step.dependOn(&run_list_update_tests.step);
    test_step.dependOn(&run_webview2_tests.step);
    test_step.dependOn(&run_downloads_tests.step);
    test_step.dependOn(&run_downloads_page_tests.step);
    test_step.dependOn(&run_history_tests.step);
    test_step.dependOn(&run_history_page_tests.step);
    test_step.dependOn(&run_browser_tests.step);
}

fn createNimloModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addAnonymousImport("start_page_asset", .{
        .root_source_file = b.path("assets/start_page/start_page.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addAnonymousImport("about_page_asset", .{
        .root_source_file = b.path("assets/about_page/about_page.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addAnonymousImport("filter_lists_asset", .{
        .root_source_file = b.path("assets/filters/filter_assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    return module;
}

fn addWindowsSystemLibraries(module: *std.Build.Module) void {
    // Cross-linked from any host via Zig's bundled mingw-w64 import libraries.
    module.linkSystemLibrary("user32", .{});
    module.linkSystemLibrary("ole32", .{});
}

fn webview2LoaderSourcePath(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "windows/webview2/arm64/WebView2Loader.dll",
        else => "windows/webview2/x64/WebView2Loader.dll",
    };
}

fn addMacosSdkPaths(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    const sysroot = b.sysroot orelse return;
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
}
