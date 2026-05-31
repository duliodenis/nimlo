Nimlo Browser SPEC

1. Project Summary

Nimlo is an open-source, lightweight, modern browser project written primarily in Zig. The first version is not intended to replace Chrome, Safari, Firefox, or Chromium at the engine level. Instead, Nimlo starts as a practical browser shell that uses the operating system’s native WebView/WebKit-based rendering capability while building the surrounding browser experience in Zig.

The long-term goal is to gradually replace isolated browser infrastructure with Zig-native components where it makes sense: URL parsing, navigation logic, history, bookmarks, downloads, local search, storage, privacy controls, caching, and eventually an experimental rendering engine.

2. Product Philosophy

Nimlo exists because the browser market has become too centralized, too heavy, too ad-driven, and increasingly cluttered with AI and growth features. Nimlo should feel like a return to the early magic of the web: fast, quiet, direct, and user-owned.

Core principles:

* Fast: lightweight startup, responsive UI, low overhead.
* Private by default: no tracking, no telemetry unless explicitly enabled.
* Simple: minimal interface, understandable settings, no unnecessary features.
* Open source: transparent design, readable code, community contribution.
* User-first: no ads, no dark patterns, no forced accounts.
* Incremental: ship a useful browser shell first, then deepen the technical stack.

3. MVP Strategy

The MVP should not attempt to build a full browser engine. That would require implementing modern HTML, CSS, layout, JavaScript, rendering, security, networking, media, fonts, accessibility, and standards compliance.

Instead, the MVP should:

1. Build a desktop browser shell in Zig.
2. Use a system WebView layer for page rendering.
3. Implement browser features around that WebView.
4. Store user data locally.
5. Establish a clean architecture that allows future replacement of internal components.

Initial target platform should be macOS first, unless the implementation path makes Linux significantly easier. Cross-platform support should be planned, but not required for the first milestone.

4. High-Level Architecture
```text
Nimlo Browser
├── App Shell
│   ├── Window Management
│   ├── Tabs
│   ├── Address Bar
│   ├── Navigation Buttons
│   ├── Menu Commands
│   └── Keyboard Shortcuts
│
├── Browser Core
│   ├── Navigation Controller
│   ├── Tab Model
│   ├── Session State
│   ├── URL Handling
│   ├── Search Engine Routing
│   └── Browser Events
│
├── Web Engine Adapter
│   ├── System WebView Integration
│   ├── Page Load Events
│   ├── JavaScript Bridge, if needed
│   ├── Back/Forward State
│   └── Future Engine Abstraction
│
├── Storage
│   ├── Preferences
│   ├── History
│   ├── Bookmarks
│   ├── Downloads Metadata
│   └── Session Restore
│
├── Privacy and Security
│   ├── Private Windows
│   ├── Permission Prompts
│   ├── Local-Only Data Policy
│   ├── Basic Tracking Protection Hooks
│   └── Future Sandboxing Strategy
│
├── Downloads
│   ├── Download Start
│   ├── Download Progress
│   ├── Save Location
│   ├── Completion State
│   └── Failure Handling
│
├── Settings
│   ├── Homepage
│   ├── Default Search Engine
│   ├── Privacy Options
│   ├── Theme
│   └── Data Management
│
└── Experimental Engine
    ├── HTML Parser
    ├── CSS Parser
    ├── DOM Model
    ├── Layout Engine
    ├── Paint Engine
    └── Optional JavaScript Runtime
```
5. The 10 Major Browser Parts

5.1 App Shell

The App Shell is the visible desktop application.

Responsibilities:

* Create the application window.
* Display the top browser chrome.
* Manage tabs.
* Provide the address/search bar.
* Provide back, forward, reload, stop, and new tab controls.
* Handle keyboard shortcuts.
* Route user actions into the Browser Core.

MVP requirements:

* One main window.
* One active tab at startup.
* Address bar accepts URLs and search terms.
* Back, forward, reload, and stop controls.
* New tab button.
* Close tab button.
* Basic menu commands.

Out of scope for MVP:

* Full custom theming system.
* Complex profile switching.
* Extension toolbar.
* Mobile UI.

Acceptance criteria:

* User can open Nimlo.
* User can type a URL.
* Nimlo loads the page.
* User can open at least one additional tab.
* User can switch between tabs.
* User can close tabs.

5.2 Rendering Engine

The Rendering Engine turns HTML, CSS, images, fonts, and scripts into pixels.

MVP strategy:

* Do not build a rendering engine in the first release.
* Use the operating system’s WebView/WebKit-backed rendering stack through a C-compatible layer or platform-specific binding.
* Encapsulate rendering behind a WebEngineAdapter interface so it can later be replaced or supplemented.

MVP requirements:

* Load https:// and http:// pages.
* Render normal modern websites using the embedded WebView.
* Report loading state to the UI.
* Report title changes to the tab model.
* Report URL changes to the address bar.

Future requirements:

* Add an experimental Zig-native renderer for simple pages.
* Allow developer mode to open a page in either system WebView mode or experimental engine mode.

Out of scope for MVP:

* Custom HTML parser.
* Custom CSS engine.
* Custom JavaScript engine.
* Full standards compliance.

Acceptance criteria:

* Nimlo can render common pages through the system WebView.
* Tab title updates when page title changes.
* Address bar updates when navigation occurs.
* Loading indicator changes during page load.

5.3 Networking

Networking handles HTTP, HTTPS, redirects, cookies, caching, certificates, downloads, proxies, and related behavior.

MVP strategy:

* Let the system WebView handle most network loading.
* Implement only Nimlo-level request decisions where practical.
* Build a Zig-native download manager separately if possible.

MVP requirements:

* Normal page navigation works through WebView.
* HTTPS pages load correctly.
* Invalid URLs are handled gracefully.
* Search terms are routed to the configured search engine.

Future Zig-native components:

* URL parser.
* HTTP client.
* Redirect handling.
* Cache manager.
* Cookie jar.
* Certificate inspection UI.
* Proxy settings.

Out of scope for MVP:

* Full custom network stack.
* Full TLS implementation.
* Full HTTP cache implementation.
* Proxy support.

Acceptance criteria:

* User can navigate to common websites.
* User can enter a search query and land on search results.
* Bad input does not crash the app.

5.4 JavaScript Engine

Modern websites require JavaScript.

MVP strategy:

* Use the JavaScript engine provided by the system WebView.
* Do not implement or embed a separate JavaScript runtime for page execution.

MVP requirements:

* JavaScript-enabled websites work as supported by the WebView.
* Nimlo does not expose unnecessary privileged APIs to webpage JavaScript.

Future requirements:

* Optional JavaScript bridge for internal Nimlo pages.
* Strict boundary between web content and Nimlo internals.
* Developer/debug hooks.

Out of scope for MVP:

* Custom JavaScript engine.
* V8 integration.
* JavaScriptCore embedding outside WebView.
* Extension scripting API.

Acceptance criteria:

* JavaScript-heavy sites load through WebView.
* Web content cannot directly access Nimlo storage or settings.

5.5 HTML Parser

The HTML parser converts HTML source into a document tree.

MVP strategy:

* Use the WebView’s parser.
* Do not build a custom HTML parser for the first usable browser.

Future experimental engine requirements:

* Parse a limited subset of HTML.
* Support basic tags:
    * html
    * head
    * title
    * body
    * h1 through h6
    * p
    * a
    * img
    * ul
    * ol
    * li
    * div
    * span
    * br
* Build a simple DOM-like tree.
* Preserve text nodes.
* Ignore unsupported tags safely.

Out of scope for MVP:

* Standards-complete parsing.
* Error recovery for malformed real-world HTML.
* Scripting integration.

Acceptance criteria for future experimental engine:

* Given a simple HTML file, Nimlo can parse it into a tree.
* The tree can be printed in debug mode.
* Unsupported tags do not crash the parser.

5.6 CSS Engine

The CSS engine parses styles and applies them to the document tree.

MVP strategy:

* Use the WebView’s CSS engine.
* Do not implement CSS in the initial browser shell.

Future experimental engine stages:

Stage 1:

* Inline styles.
* Element selectors.
* Basic colors.
* Font size.
* Margins and padding.

Stage 2:

* Class selectors.
* ID selectors.
* Basic cascade rules.
* Simple inheritance.

Stage 3:

* Block layout.
* Width and height.
* Basic borders and backgrounds.

Stage 4:

* Flexbox subset.
* Media query subset.

Out of scope for MVP:

* Custom CSS parser.
* Flexbox.
* Grid.
* Animations.
* Transforms.
* Complex cascade.

Acceptance criteria for future experimental engine:

* A simple stylesheet can be parsed.
* Element styles can be computed.
* Basic visual styling affects rendering.

5.7 Layout Engine

The layout engine decides where elements appear on screen.

MVP strategy:

* Use the WebView’s layout engine.
* Do not build layout for the initial product.

Future experimental engine requirements:

* Viewport model.
* Block layout.
* Inline text layout.
* Basic line wrapping.
* Image dimensions.
* Scrollable document area.

Out of scope for MVP:

* Custom layout.
* Flexbox.
* CSS Grid.
* Tables.
* Complex typography.
* Bidirectional text.

Acceptance criteria for future experimental engine:

* Simple pages render in a readable vertical layout.
* Paragraphs wrap correctly within the viewport.
* Links and images occupy sensible positions.
* Page can scroll.

5.8 Graphics and Compositing

Graphics and compositing draw the page and browser UI.

MVP strategy:

* Use native/system rendering for the WebView.
* Use the selected app UI strategy for browser chrome.
* Avoid building a custom GPU compositor in the first version.

MVP requirements:

* Browser chrome displays cleanly.
* Web content renders through WebView.
* Resize events work.
* Page area updates when the window changes size.

Future requirements:

* Custom rendering surface for experimental engine.
* Text rendering.
* Image decoding.
* Basic shapes.
* GPU acceleration exploration.

Out of scope for MVP:

* Custom compositor.
* Video rendering.
* Advanced font shaping.
* SVG rendering.
* Canvas implementation.

Acceptance criteria:

* The app window is visually stable.
* Pages resize properly.
* UI remains responsive during page loads.

5.9 Security Sandbox

A real browser must isolate untrusted web content from the application and the operating system.

MVP strategy:

* Rely on the system WebView’s existing security boundaries where available.
* Do not expose privileged APIs to web content.
* Treat the MVP as an experimental browser shell, not a hardened security product.

MVP requirements:

* No direct filesystem access from web content.
* No direct access to Nimlo settings or history from web content.
* Permission prompts should be handled conservatively.
* Unknown or unsupported permissions should be denied by default.

Future requirements:

* Multi-process architecture.
* Renderer process isolation.
* Network process separation.
* Strict content permissions.
* Site data controls.
* Security audit checklist.

Out of scope for MVP:

* Full custom sandbox.
* Full permission manager.
* Extension security model.
* Hardened multi-process architecture.

Acceptance criteria:

* Web pages cannot call arbitrary Zig functions.
* Internal app pages and external web pages are clearly separated.
* Permission-sensitive features default to safe behavior.

5.10 Product Layer

The Product Layer is where Nimlo becomes more than a WebView demo.

MVP requirements:

* Clear start page.
* Local bookmarks.
* Local history.
* Configurable search engine.
* Simple settings page.
* Private window or private tab mode.
* No telemetry.
* No ads.
* No forced account.

Future differentiators:

* Built-in RSS reader.
* Local-first reading list.
* Local history search.
* Privacy dashboard.
* Minimal tracker blocking.
* Clean reader mode.
* Exportable bookmarks/history.
* Open governance model.
* Optional classic-search integration.

Out of scope for MVP:

* Sync.
* Accounts.
* Extension store.
* AI assistant features.
* Cloud backend.
* Monetization.

Acceptance criteria:

* Nimlo feels like a simple browser, not a demo.
* User can launch it, browse, save pages, view history, and change basic settings.
* No user data leaves the machine.

6. Proposed Repository Structure
```text
nimlo/
├── README.md
├── SPEC.md
├── LICENSE
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   ├── app/
│   │   ├── app.zig
│   │   ├── window.zig
│   │   ├── commands.zig
│   │   └── shortcuts.zig
│   │
│   ├── browser/
│   │   ├── browser.zig
│   │   ├── tab.zig
│   │   ├── tab_manager.zig
│   │   ├── navigation.zig
│   │   ├── url_input.zig
│   │   └── search_engine.zig
│   │
│   ├── webview/
│   │   ├── webview_adapter.zig
│   │   ├── webview_platform.zig
│   │   └── webview_events.zig
│   │
│   ├── storage/
│   │   ├── db.zig
│   │   ├── preferences.zig
│   │   ├── history.zig
│   │   ├── bookmarks.zig
│   │   └── sessions.zig
│   │
│   ├── downloads/
│   │   ├── download.zig
│   │   └── download_manager.zig
│   │
│   ├── privacy/
│   │   ├── private_mode.zig
│   │   ├── permissions.zig
│   │   └── tracking.zig
│   │
│   ├── ui/
│   │   ├── chrome.zig
│   │   ├── start_page.zig
│   │   ├── settings_page.zig
│   │   └── assets.zig
│   │
│   └── experimental_engine/
│       ├── html_parser.zig
│       ├── css_parser.zig
│       ├── dom.zig
│       ├── layout.zig
│       └── paint.zig
│
├── assets/
│   ├── logo.svg
│   ├── app_icon.png
│   └── start_page/
│
├── tests/
│   ├── url_input_tests.zig
│   ├── search_engine_tests.zig
│   ├── storage_tests.zig
│   └── history_tests.zig
│
└── docs/
    ├── architecture.md
    ├── roadmap.md
    ├── privacy.md
    └── contributing.md
```
7. Core Data Models

7.1 Tab
```text
Tab
├── id
├── title
├── current_url
├── loading_state
├── can_go_back
├── can_go_forward
├── is_private
└── webview_handle
```
7.2 History Entry
```text
HistoryEntry
├── id
├── url
├── title
├── visit_time
├── visit_count
└── last_visit_time
```
7.3 Bookmark
```text
Bookmark
├── id
├── title
├── url
├── folder_id
├── created_at
└── updated_at
```
7.4 Preferences
```text
Preferences
├── homepage_url
├── default_search_engine
├── open_previous_session
├── private_mode_default
├── theme
├── download_directory
└── telemetry_enabled
```
telemetry_enabled must default to false. The MVP should avoid implementing telemetry at all unless explicitly required later.

8. Storage Requirements

MVP storage may use SQLite or simple local files. SQLite is preferred if dependency setup is manageable.

Required persisted data:

* Preferences.
* Bookmarks.
* History.
* Session restore state.
* Download metadata.

Private mode rules:

* Do not write history.
* Do not persist cookies through Nimlo-managed storage.
* Do not persist session state.
* Do not persist form/search data.

9. URL and Search Behavior

The address bar should accept both URLs and search terms.

Rules:

1. If input starts with http:// or https://, treat it as a URL.
2. If input looks like a domain, normalize to https://domain.
3. If input is plain text, route it to the configured search engine.
4. If input is malformed, show a non-crashing error state or route to search.

Default search engine should be configurable. The initial default may be DuckDuckGo or another privacy-friendly option, but this should be easy to change.

10. Internal Pages

Nimlo should support internal pages using a reserved scheme such as:

- nimlo://start
- nimlo://settings
- nimlo://history
- nimlo://bookmarks
- nimlo://downloads
- nimlo://about

Internal pages should be rendered separately from arbitrary external websites. Do not allow external websites to access privileged internal APIs.

MVP internal pages:

* nimlo://start
* nimlo://settings
* nimlo://history
* nimlo://bookmarks
* nimlo://about

11. MVP Milestones

Milestone 0.1: Window and Single Page Load

Goal:

* Launch app.
* Open one window.
* Display one WebView.
* Load a default start page or homepage.
* Load a typed URL.

Acceptance criteria:

* zig build run launches Nimlo.
* User can type https://example.com.
* Page loads successfully.
* App does not crash on bad input.

Milestone 0.2: Browser Chrome

Goal:

* Add basic browser controls.

Acceptance criteria:

* Address bar visible.
* Back button works.
* Forward button works.
* Reload button works.
* Stop loading works if supported.
* Page title appears in tab/window title.

Milestone 0.3: Tabs

Goal:

* Support multiple tabs.

Acceptance criteria:

* New tab button creates a tab.
* User can switch tabs.
* User can close tabs.
* Each tab maintains independent URL and history state.

Milestone 0.4: Local History and Bookmarks

Goal:

* Persist basic browsing data locally.

Acceptance criteria:

* Visited pages are added to history.
* User can bookmark current page.
* User can view bookmarks.
* User can remove bookmarks.
* History and bookmarks survive app restart.

Milestone 0.5: Settings

Goal:

* Add configurable preferences.

Acceptance criteria:

* User can set default search engine.
* User can set homepage/start page behavior.
* User can set download folder.
* Preferences survive restart.

Milestone 0.6: Private Mode

Goal:

* Add private browsing behavior.

Acceptance criteria:

* User can open private window or private tab.
* Private browsing does not write history.
* Private browsing does not persist session restore.
* Private mode is visually distinguishable.

Milestone 0.7: Downloads

Goal:

* Support basic file downloads.

Acceptance criteria:

* Download starts when user clicks a downloadable file.
* User can choose or use default save location.
* Download progress is visible.
* Completed download appears in downloads list.

Milestone 1.0: Lightweight Daily-Use Browser Shell

Goal:

* Nimlo is usable as a simple daily browser for basic browsing.

Acceptance criteria:

* Stable window, tabs, navigation, bookmarks, history, settings, private mode, and downloads.
* No telemetry.
* No ads.
* No forced account.
* Local-first storage.
* Packaged release for the initial target platform.

12. Non-Goals for MVP

Do not implement these in the MVP:

* Custom rendering engine.
* Custom JavaScript engine.
* Browser extension system.
* Account sync.
* Cloud backend.
* AI features.
* Built-in advertising.
* Full tracker blocker.
* Full certificate manager.
* Full security sandbox.
* Cross-platform parity.
* Mobile app.

13. Technical Guidance for Codex

Codex should prioritize a working vertical slice over broad abstractions.

Implementation rules:

1. Keep Zig code small and modular.
2. Prefer explicit error handling.
3. Avoid global mutable state unless justified.
4. Keep platform-specific code behind interfaces.
5. Add tests for pure logic modules first.
6. Do not overbuild the experimental engine.
7. Avoid introducing a large framework unless absolutely necessary.
8. Preserve the ability to replace the WebView adapter later.
9. Keep user data local.
10. Make the app runnable from zig build run.

Suggested first implementation order:

1. Create project skeleton.
2. Create app window.
3. Embed WebView.
4. Load default start page.
5. Add address bar.
6. Add URL/search normalization.
7. Add navigation controls.
8. Add tab model.
9. Add persistence layer.
10. Add bookmarks/history.

14. Testing Strategy

Pure Zig modules should have unit tests.

Test first:

* URL normalization.
* Search query routing.
* Bookmark storage.
* History storage.
* Preferences loading/saving.
* Private mode storage rules.

Manual tests:

* Launch app.
* Load https://example.com.
* Search for text from address bar.
* Open a new tab.
* Close a tab.
* Bookmark page.
* Restart app and confirm bookmark remains.
* Visit page and confirm history appears.
* Use private mode and confirm no history entry is written.

15. Privacy Requirements

Nimlo must be private by default.

MVP privacy rules:

* No telemetry.
* No analytics.
* No crash reporting unless explicitly added later as opt-in.
* No account system.
* No remote config.
* No sponsored content.
* No ads.
* No default data upload.

Data should remain on the user’s device unless the user intentionally navigates to a website or uses a search engine.

16. Branding Notes

Product name:

* Nimlo

Positioning lines:

* “Fast. Private. Simple. Open source.”
* “Browse lightly.”
* “A small browser for the quiet web.”

Visual direction:

* Minimal.
* Soft purple/indigo accent.
* Rounded geometry.
* Clean white/light interface.
* Calm, non-corporate feel.

17. Future Roadmap

After MVP 1.0, consider:

1. Reader Mode

A clean reading experience that strips clutter from articles.

2. RSS and Personal Web

Allow users to follow websites directly without social feeds.

3. Local History Search

Fast local search across titles, URLs, and possibly saved page text.

4. Tracker Blocking

Use a simple blocklist-based approach first.

5. Import/Export

Support bookmarks import/export using common formats.

6. Experimental Zig Engine

Add a toy rendering path for simple HTML/CSS documents.

7. Extension-Like Scripts

Only after a strong security model exists.

8. Cross-Platform Builds

Expand from initial platform to Linux and Windows.

18. Definition of Done for MVP

The MVP is done when a user can:

1. Install or run Nimlo.
2. Open the browser.
3. Navigate to websites.
4. Use search from the address bar.
5. Open and close tabs.
6. Go back, forward, and reload.
7. Bookmark pages.
8. View local history.
9. Download files.
10. Open a private session.
11. Change basic settings.
12. Close and reopen the app without losing non-private bookmarks/preferences.

The MVP is not required to be a secure replacement for mainstream browsers. It is a working open-source lightweight browser shell and foundation for future development.

19. First Codex Task

Codex should begin with Milestone 0.1.

Task:

Create the initial Nimlo Zig project skeleton with a runnable desktop window that embeds a WebView or system web rendering component and loads a default start page.

Expected output:

* build.zig
* src/main.zig
* Minimal WebView integration
* Placeholder start page
* README instructions for running locally

Acceptance criteria:

* zig build run launches the app.
* A window appears.
* The window displays a page.
* The app exits cleanly.
