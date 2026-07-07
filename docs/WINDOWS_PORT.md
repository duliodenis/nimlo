# Windows Port Plan — Road to 0.7 Parity

Step-by-step handoff plan for bringing the Windows build (Win32 + WebView2) to
feature parity with macOS through milestone 0.7. Written to be executable
without prior context: each phase lists its goal, the work, the files, the
Windows-specific traps, and an exit gate. Phases are strictly ordered — do not
start a phase until the previous phase's gate passes.

The milestone definitions are the checklists in `README.md` ("MVP Roadmap");
the product spec is `docs/SPECS.md`. The macOS implementation is the reference
for behavior; when in doubt, do what macOS does.

## Where things stand

Done (compiles and links from any host, **not executed on real
Windows yet**):

- `src/app/window_win32.zig` — window class, message pump, per-window state in
  `GWLP_USERDATA`, `WM_SIZE` resize forwarding, `WM_ACTIVATE` sink
  re-activation, deferred `WM_CLOSE`-based close, per-monitor-v2 DPI.
- `src/webview/webview2.zig` — raw COM bridge (GUIDs, vtable prefixes for
  `ICoreWebView2Environment`/`Controller`/`ICoreWebView2`, generic
  Zig-implemented `CompletedHandler` COM object). Unit-tested, runs in
  `zig build test` on any host.
- `src/webview/webview_win32.zig` — async environment/controller bootstrap via
  vendored `WebView2Loader.dll` (`windows/webview2/`, package 1.0.2903.40),
  pending-load queue flushed when the controller arrives, `Navigate` /
  `NavigateToString`, owner-keyed sinks by HWND.
- Build: `zig build -Dtarget=x86_64-windows` → `nimlo.exe` + loader DLL;
  `zig build check-windows` (x86_64 + aarch64 link check);
  `zig build check-portable` (Linux stub guard).

Not started: everything visible — chrome, tabs, events, menus, internal-page
actions, drag machine, downloads.

## Ground rules (apply to every phase)

1. **The seam is sacred.** Platform selection stays in `window_platform.zig` /
   `webview_platform.zig` comptime switches. All chrome↔browser↔app
   communication goes through the `EventSink`/`ChromeSink`/`AppSink` function
   pointers in `src/webview/webview_events.zig` carrying plain data and opaque
   `*anyopaque` handles. The browser core (`src/browser/`, `src/storage/`,
   `src/ui/*_page.zig`) must not change for Windows; if it seems to need to,
   the design is wrong — extract shared logic instead.
2. **Logic lives in shared tested modules.** Geometry, string handling, drag
   state machines, and route dispatch are already extracted
   (`src/ui/tab_strip_layout.zig`, `tab_drag_logic.zig`, `web_strings.zig`,
   `internal_routes.zig`). Windows chrome consumes them with scalar inputs; new
   logic of this kind gets its own tested module registered in `build.zig`.
3. **Verification gate for every change:** `zig build test`,
   `zig build check-windows`, `zig build check-portable`, and the macOS
   `zig build` must all stay green. Runtime claims require a run on Windows
   (machine, VM, or CI) — `check-windows` green is necessary, never sufficient.
4. **Conventions:** events are `emitXxx`/`handleXxx`/`on_xxx`; COM/Win32
   declarations stay raw and in-file (the `objc_msgSend` ethos — no binding
   generators, no SDK headers); allocation via `std.heap.page_allocator`
   matching the macOS platform files; debug prints mirror the macOS wording
   with a `win32` prefix.
5. **Carry-over platform lessons:** re-activate per-window sinks on focus
   change (`WM_ACTIVATE`, already wired — extend to chrome focus changes);
   never destroy a window from inside message dispatch (post `WM_CLOSE`);
   beware modal message loops (menus, drags) starving async COM callbacks.

## COM technical notes (read before Phase 1)

- **Interface versions:** WebView2 evolves via `ICoreWebView2_2 … _27`
  obtained by `QueryInterface` on `ICoreWebView2`, not by casting. Add a typed
  `queryInterface` helper to `webview2.zig` and the IIDs per feature
  (downloads need `ICoreWebView2_4`, favicons `ICoreWebView2_15`). Always
  handle `E_NOINTERFACE` gracefully — old runtimes exist.
- **Events:** `add_Xxx(handler, *EventRegistrationToken)` where the handler is
  IUnknown + `Invoke(sender, args)`. Add a generic `EventHandler(Sender, Args,
  iid)` to `webview2.zig` beside `CompletedHandler` (same refcount pattern;
  `Invoke` has two interface pointers instead of HRESULT+result). Store tokens
  if you ever need `remove_Xxx`; for webviews destroyed with their tab it is
  fine to skip removal and just `Release`.
- **String out-params are CoTaskMem:** every `LPWSTR*` getter
  (`get_Source`, `get_DocumentTitle`, `get_ResultFilePath`, …) returns memory
  that must be freed with `CoTaskMemFree` (ole32) after converting to UTF-8.
  Add `utf8FromUtf16CoTaskMem` next to `utf16ZFromUtf8` and use it everywhere.
- **One environment per process.** Multiple environments over the same user
  data folder must have identical options, and multi-window (Phase 6 and the
  app-sink `on_new_window_requested`) makes per-window environments fragile.
  Refactor in Phase 3: cache the `ICoreWebView2Environment` in a module-level
  var in `webview_win32.zig`; subsequent windows reuse it and only create
  controllers.
- **Vtable slots are position-critical.** Transcribe from `WebView2.idl` in
  the vendored NuGet package (pin the same version, 1.0.2903.40) in exact
  order; a one-slot error compiles fine and corrupts calls at runtime. This is
  the class of bug only a Windows run catches.
- **Accelerators bypass the message loop while the webview has focus.** Use
  `ICoreWebView2Controller::add_AcceleratorKeyPressed` for shortcuts when the
  page has focus, plus normal `WM_KEYDOWN`/`TranslateAcceleratorW` handling for
  chrome focus. Both paths must funnel into the same command dispatch.

## Phase 0 — Runtime bring-up and CI

Goal: prove the 0.1 scaffolding on real Windows and make Windows verification
continuous, so later phases never stack unverified work on unverified work.

1. Commit the 0.1 scaffolding if not yet committed.
2. GitHub Actions workflow (`.github/workflows/ci.yml`):
   - any-OS job: `zig build test`, `check-portable`, `check-windows`.
   - `windows-latest` job: build natively, then run `nimlo.exe` with a smoke
     script — assert the log lines `win32 window ready`, `win32 WebView2
     environment requested`, `win32 WebView2 controller ready` appear, then
     kill it. Also run once with `NIMLO_START_URL=https://example.com` and
     assert the queued-load log.
3. Manual checklist on a Windows 11 machine/VM (ARM VM on Apple Silicon pairs
   with the aarch64 build): window centered at 1024×768, start page renders,
   live resize tracks, `NIMLO_START_URL` navigates, close exits the process,
   profile data appears under `%APPDATA%\.nimlo\webview2`.
4. Fix what breaks; suspect vtable slot order and ABI first.
5. Update the memory/status notes: after this phase, "runtime-verified" may be
   claimed for 0.1.

Exit gate: CI green including the Windows smoke job; manual checklist passed.

## Phase 1 — Navigation event bridge (substrate for 0.2)

Goal: WebView2 → `emitNavigation`, so the core's tab state, history hooks, and
(the future) address bar reflect reality. No visible UI change.

1. `webview2.zig`: generic `EventHandler`, `EventRegistrationToken`,
   `queryInterface` helper, `utf8FromUtf16CoTaskMem`; vtable prefixes + IIDs
   for `NavigationStarting`/`NavigationCompleted`/`SourceChanged`/
   `ContentLoading`/`DocumentTitleChanged`/`HistoryChanged` args and, via
   `ICoreWebView2_15`, `FaviconChanged`/`get_FaviconUri`. Unit-test the new
   helpers (handler refcounting, token plumbing) — they run on any host.
2. `webview_win32.zig`: after controller-ready, subscribe and translate into
   `webview_events.NavigationEvent` (`url`, `title`, `favicon_url`,
   `loading_state` idle/loading/failed, `can_go_back`/`can_go_forward` from
   HistoryChanged getters, `source_handle` = the `ICoreWebView2` pointer, which
   is already what `activeHandle()` returns).
3. Internal-page URL discipline: `NavigateToString` reports `about:blank`-ish
   sources. Mirror macOS `noteInternalLoadForUrl`/`noteExternalLoad`: track the
   logical URL per webview in the Windows layer and substitute it in emitted
   events. Put this map where chrome can also read it (it becomes
   `chrome_win32` state in Phase 2).
4. `NewWindowRequested`: intercept, `args.put_Handled(true)`, route the URI as
   a new-tab request (`emitUrlOpenRequested` semantics matching macOS).

Exit gate: CI smoke asserts a navigation log line with title + URL for a real
site; back/forward capability flags observed flipping in logs.

## Phase 2 — 0.2 parity: chrome with controls and address bar

Goal: README 0.2 checklist on Windows — address bar, back, forward, reload,
stop, title updates.

1. New `src/ui/chrome_win32.zig` (the counterpart of `chrome_macos.zig` —
   expect it to grow through every later phase; keep phase-sized commits).
   Native Win32 children in a chrome band at the top of the client area:
   an `EDIT` control for the address bar (subclassed for Enter/Escape/select-
   all), owner-drawn or `BUTTON` children for back/forward/reload/stop.
   `chrome_height` constant analogous to macOS; the controller bounds become
   `{0, chrome_height, width, height}` — update `applyClientBounds`/resize.
2. Wire controls → existing sinks: Enter in the address bar →
   `emitActiveTabUrlRequested` (URL/search normalization is shared core:
   `src/browser/url_input.zig`); back/forward →
   `emitActiveTabBack/ForwardRequested`; reload/stop → whatever macOS emits
   (check `chrome_macos.zig` for the exact events; reuse them, do not invent).
3. Chrome consumes navigation state: implement the `ChromeSink` for Windows
   (`on_tabs_changed` can stay minimal until Phase 3) and update address-bar
   text, title (`SetWindowTextW` on the top-level window), button
   enabled-states, and a loading indicator from `NavigationEvent`s.
4. Window title = active page title, matching macOS behavior.
5. Focus rules: clicking the page must return key events to the webview
   (`MoveFocus`); `WM_ACTIVATE` already re-activates sinks — verify chrome
   state re-syncs on focus too.

Exit gate: README 0.2 boxes demonstrably work in a manual pass on Windows; CI
smoke extended to drive one navigation via `NIMLO_START_URL` and assert the
title reaches the log.

## Phase 3 — 0.3 parity: tabs

Goal: real `createWebView`/`showWebView`/`destroyWebView` — one WebView2
controller per tab — plus a native tab strip.

1. Shared-environment refactor (see COM notes): module-level cached
   environment; controller creation becomes a small async helper since tab
   creation is also synchronous in the core (`browser.zig` calls
   `createWebView() → handle` and expects a usable handle immediately).
   **Design decision to make deliberately:** macOS returns the `WKWebView` id
   synchronously. WebView2 cannot. Options: (a) allocate a per-tab proxy
   struct synchronously — the opaque handle the core sees — holding
   `controller`/`core` pointers filled in by the completion callback, with its
   own pending-load queue (generalize the existing single pending-load); or
   (b) block on a nested message pump until the controller arrives (rejected:
   nested pumps are the macOS-modal-session bug all over again). Choose (a);
   `activeHandle()` and `event source_handle` then use the proxy pointer, which
   also fixes "handle changes when controller arrives".
2. `showWebView`: `put_IsVisible(true)` on the shown tab's controller,
   `false` on the rest (the macOS `setHidden:` loop). `destroyWebView`:
   `Close()` the controller, `Release` controller+core, free the proxy —
   the "native WebView cleanup on close" checkbox.
3. Tab strip in `chrome_win32.zig`: custom-drawn child window using
   `src/ui/tab_strip_layout.zig` for slot widths, hit-testing, and indices
   (scalar inputs — no Win32 types in the shared module). Click to activate
   (`emitTabActivatedRequested`), close glyph (`emitTabClosedRequested`),
   new-tab button (`emitNewTabRequested`). `on_tabs_changed` redraws from
   `TabSnapshot`s.
4. Per-tab state (URL/title/favicon/loading/back-forward) is core-owned and
   already flows through Phase 1 events keyed by `source_handle` — verify the
   proxy-handle keying holds up.

Exit gate: README 0.3 checklist manual pass; open/switch/close ~20 tabs
without leaking controllers (watch process count/memory — each WebView2 tab
spawns runtime child processes; closed tabs must release them).

## Phase 4 — 0.4 parity: keyboard and menu commands

Goal: focus address bar, new/close tab, reload, back/forward, next/previous
tab — from keyboard and a menu.

1. Command dispatch table in `chrome_win32.zig` mapping command ids →
   the same sink emissions the buttons use (`emitAddressBarFocusRequested`
   comes to chrome via `ChromeSink.on_address_bar_focus_requested` on macOS —
   trace the exact flow in `chrome_macos.zig` and mirror it).
2. Shortcuts, both input paths (see COM notes): Ctrl+L, Ctrl+T, Ctrl+W,
   Ctrl+R, Alt+Left/Right, Ctrl+Tab / Ctrl+Shift+Tab —
   `add_AcceleratorKeyPressed` when the webview has focus, accelerator
   handling in the message pump when chrome has focus. One dispatch table,
   two entry points.
3. Menu bar: `CreateMenu`/`AppendMenuW` + `WM_COMMAND` → same dispatch table.
   Match the macOS menu structure where it makes sense on Windows.
4. Multi-window correctness: commands act on the focused window's browser —
   this is exactly what owner-keyed sink activation guarantees; add a
   two-window CI/manual check the moment Phase 6 lands.

Exit gate: README 0.4 checklist manual pass with focus in the page AND focus
in the address bar (the two accelerator paths).

## Phase 5 — 0.5 parity: history and bookmarks

Goal: `nimlo://history` and `nimlo://bookmarks` full behavior. Almost all of
this is shared code already — the page HTML (`src/ui/*_page.zig`), storage
(`src/storage/`), search, and selection logic came along for free. The Windows
work is routing.

1. Intercept internal action URLs: in `NavigationStarting`, URLs under
   `https://nimlo.internal/` → `args.put_Cancel(true)` and dispatch through
   `src/ui/internal_routes.zig`. Emit-only routes fire portable events; the
   returned platform decisions (`clear_history` confirmation, open/reveal
   paths) get Windows implementations.
2. Confirmation dialogs: history bulk-delete and clear-history confirmations
   (`ChromeSink.on_history_clear_confirmation_requested`) → `TaskDialog` or
   `MessageBoxW`. Beware: message boxes run modal loops — emit resulting
   events after dismissal, and never from inside `WM_CLOSE` teardown.
3. Toolbar star: bookmark toggle button in chrome →
   `emitBookmarkCurrentPageToggleRequested`; reflect `can_bookmark` /
   `is_bookmarked` from `TabSnapshot`.
4. Internal-page reload after mutations flows through
   `on_internal_page_reload_requested` — confirm the loadHtml path + logical
   URL tracking from Phase 1 round-trips (page action → route → storage →
   re-render → NavigateToString → correct address-bar text).
5. Keyboard/range selection inside the pages is in-page JS — verify, don't
   port.

Exit gate: README 0.5 checklist manual pass; history/bookmarks JSONL files
byte-format-compatible with macOS (same stores, same shape — copy a file
across OSes as the test).

## Phase 6 — 0.6 parity: window and tab management

The hardest phase: reorder, tear-off with drag-follow, cross-window move,
re-dock, close-empty-window, per-window active tab. The state machine already
exists (`src/ui/tab_drag_logic.zig`: `TabDragState`, tear-off threshold,
detached placement math) — Windows supplies mouse plumbing and window ops.

1. Drag tracking in the tab strip: `SetCapture` on mouse-down, feed
   `WM_MOUSEMOVE` points (screen coords) into `TabDragState`, `ReleaseCapture`
   on up/cancel. Render reorder previews / drop indicators from
   `tab_strip_layout` outputs.
2. Reorder within a window → `emitTabReorderedRequested`.
3. Tear-off: threshold crossing → `emitTabDetachRequested` with
   `DetachedWindowPlacement` from the shared placement math; the app layer
   (`app.zig`, unchanged) creates the new window. Drag-follow: move the new
   window with the cursor during the remainder of the drag (`SetWindowPos`);
   respect `defer_empty_source_close` — keep the emptied source window hidden
   (`ShowWindow(SW_HIDE)`) until drag end, then close it (this is the macOS
   ghost-window/close-source regression area; the `NIMLO_CLOSE_SOURCE_TEST`
   variants document the traps).
4. Cross-window move/re-dock: hit-test other Nimlo windows during drag
   (`WindowFromPoint` + verifying the class name), gate on
   `emitTabMoveTargetAvailable`, drop → `emitTabMoveToWindowRequested` with
   insertion index from the destination's strip layout.
5. Multi-window plumbing checks: shared environment (Phase 3) across windows;
   `open_window_count`/`PostQuitMessage` behavior with >1 window; sink
   activation on every focus handoff during drags.
6. Port the self-test hooks now — they exist because this phase regresses
   silently: `NIMLO_TEAR_OFF_TEST` (in-process drag replay through the same
   code path as real mouse input — feed synthetic points into the drag
   machine, do NOT synthesize OS input events) and `NIMLO_CLOSE_SOURCE_TEST`.
   Wire them into `runEventLoop` like macOS and run them in Windows CI.

Exit gate: README 0.6 checklist manual pass; `NIMLO_TEAR_OFF_TEST` and
`NIMLO_CLOSE_SOURCE_TEST` variants green in Windows CI.

## Phase 7 — 0.7 parity: downloads

Goal: download tracking, `nimlo://downloads`, JSONL persistence, open/reveal,
remove/clear. Storage (`src/storage/downloads.zig`), the page, and the events
all exist; Windows supplies the WebView2 download hookup and two shell verbs.

1. `webview2.zig`: `ICoreWebView2_4` (QueryInterface) + `add_DownloadStarting`;
   `ICoreWebView2DownloadStartingEventArgs` (`get_DownloadOperation`,
   `put_ResultFilePath` if redirecting to the user's Downloads dir — resolve
   via `SHGetKnownFolderPath(FOLDERID_Downloads)`, shell32);
   `ICoreWebView2DownloadOperation` (`get_Uri`, `get_ResultFilePath`,
   `get_TotalBytesToReceive`, `get_BytesReceived`, `get_State`,
   `add_StateChanged`).
2. Map lifecycle → owner-keyed emissions (downloads must reach their owning
   window even when it is not focused — that is why the ForOwner variants
   exist): start → `emitDownloadStartedForOwner` (returns record id),
   completed → `emitDownloadFinishedForOwner` with byte size, interrupted →
   `emitDownloadFailedForOwner`. Keep the `DownloadOperation` alive
   (AddRef) until a terminal state, then Release.
3. Platform decisions from `internal_routes`: open file →
   `ShellExecuteW("open", path)`; "reveal" (Finder ≙ Explorer) →
   `explorer.exe /select,"path"`. Missing-file handling matches macOS.
4. Port `NIMLO_DOWNLOAD_TEST=<url>` into `runEventLoop` (the hook slot is
   already noted there) and add a CI download smoke against a small file.

Exit gate: README 0.7 checklist manual pass on Windows; `NIMLO_DOWNLOAD_TEST`
green in Windows CI; `downloads.jsonl` cross-OS compatible.

## Cross-cutting parity items (schedule opportunistically)

- **Privacy parity** (best before Phase 5 makes storage user-visible): macOS
  uses a non-persistent data store. WebView2 equivalent: QueryInterface the
  environment to `ICoreWebView2Environment10`,
  `CreateCoreWebView2ControllerOptions` + `put_IsInPrivateModeEnabled(true)`,
  `CreateCoreWebView2ControllerWithOptions`. TODO marker already sits in
  `webview_win32.attachToWindow`.
- **Quit/close confirmation:** mirror `confirmQuitIfNeeded` /
  `confirmWindowCloseIfNeeded` (multi-tab window close prompt) via `WM_CLOSE`
  handling once tabs exist (Phase 3+).
- **App shell polish** (any time after Phase 2): flip to the Windows GUI
  subsystem (`exe.subsystem = .Windows`) once console logs stop earning their
  keep — route logs to `OutputDebugStringW` or a file first; `.rc`-free icon
  embedding (Zig can add `.manifest`/resources via `exe.addWin32ResourceFile`)
  and a proper app manifest (DPI awareness declared in-manifest beats the
  runtime call).
- **README:** tick Windows-parity progress as phases land (note: the macOS
  0.7 checkboxes in README are still unticked despite being shipped — fix in
  passing).

## Definition of done

Every README checkbox 0.1–0.7 demonstrably true on Windows; `zig build test`,
`check-portable`, `check-windows`, macOS `zig build` all green; Windows CI
running the smoke run plus the three env-gated self-tests; history, bookmarks,
and downloads JSONL files interchangeable between macOS and Windows; no
changes to `src/browser/`, `src/storage/`, or `src/ui/*_page.zig` that exist
only to serve Windows.
