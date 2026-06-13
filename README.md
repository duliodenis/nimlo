# Nimlo

A lightweight, open-source browser built in Zig for fast, private, user-controlled web navigation.

## About
Nimlo is an experimental modern browser project focused on simplicity, speed, and the old feeling of exploring the web without clutter, ads, forced accounts, or unnecessary AI features.

The first version is intentionally modest: a clean browser shell written primarily in Zig that uses the system WebView for page rendering. Over time, Nimlo can grow its own Zig-native browser components around navigation, storage, privacy, history, bookmarks, downloads, and eventually an experimental rendering engine.

## Project Status

Nimlo is an active macOS prototype.

Current goal:

> Build a small, usable desktop browser shell with stable navigation, tabs, and local-first privacy defaults.

This is not yet a production browser and should not be treated as a secure replacement for Chrome, Safari, Firefox, or Edge.

Current prototype capabilities:

- macOS app bundle built with Zig
- Native AppKit window chrome
- Embedded WebKit `WKWebView` rendering
- Default Nimlo start page
- Address bar with URL/search normalization
- Back, forward, reload, and stop controls
- New tab, close tab, and tab switching
- Independent `WKWebView` per tab
- Per-tab URL, title, favicon, loading, and back/forward state
- Native tab strip with in-place updates
- Closed tabs destroy their native WebView
- Nonpersistent WebKit website data store by default
- Process-local WebCrypto master key for nonpersistent browsing sessions
- Local JSONL history persistence
- `nimlo://history` page with day grouping, search, multi-select, selected open/delete, delete confirmation, and keyboard/range selection controls
- Local JSONL bookmark persistence with toolbar star toggling and `nimlo://bookmarks` management
- `nimlo://bookmarks` page with search, tag editing, tag sidebar filters, untagged filtering, multi-select deletion, delete confirmation, and keyboard/range selection controls
- No telemetry or account features

## Philosophy

Modern browsers have become large, complex, corporate platforms. Nimlo is an attempt to build something smaller and calmer.

Core principles:

- Fast startup
- Minimal interface
- Local-first storage
- No ads
- No telemetry by default
- No forced accounts
- Open-source development
- User control over the browsing experience

## Why Zig?

Zig is a good fit for this project because it is:

- Small and explicit
- Fast
- Systems-oriented
- Cross-platform in spirit
- Good for building low-level infrastructure
- Easier to reason about than large C/C++ codebases

Nimlo does not try to rewrite the entire browser stack immediately. Instead, it starts with a useful shell and gradually replaces or adds components in Zig where practical.

## Planned Architecture

```text
Nimlo
├── App Shell
│   ├── Window
│   ├── Tabs
│   ├── Address Bar
│   └── Navigation Controls
│
├── Browser Core
│   ├── Navigation
│   ├── Tab State
│   ├── Session State
│   ├── URL Handling
│   └── Search Routing
│
├── WebView Adapter
│   ├── System WebView Integration
│   ├── Page Load Events
│   ├── URL Updates
│   └── Title Updates
│
├── Storage
│   ├── Preferences
│   ├── History
│   ├── Bookmarks
│   └── Sessions
│
├── Privacy
│   ├── Private Mode
│   ├── Permission Controls
│   └── Local-Only Data Rules
│
└── Experimental Engine
    ├── HTML Parser
    ├── CSS Parser
    ├── DOM
    ├── Layout
    └── Paint
```

## MVP Roadmap

### 0.1 — First Window

- [x] Launch from `zig build run`
- [x] Open a desktop window
- [x] Embed a system WebView
- [x] Load a default start page
- [x] Load a typed URL

### 0.2 — Basic Browser Controls

- [x] Address bar
- [x] Back
- [x] Forward
- [x] Reload
- [x] Stop loading
- [x] Page title updates

### 0.3 — Tabs

- [x] New tab
- [x] Close tab
- [x] Switch tabs
- [x] Independent page state per tab
- [x] Independent WebView per tab
- [x] Native WebView cleanup on close

### 0.4 — Keyboard and Menu Commands

- [x] Focus address bar
- [x] New tab
- [x] Close active tab
- [x] Reload
- [x] Back and forward
- [x] Next and previous tab

### 0.5 — History & Bookmarks

- [x] Save local browsing history
- [x] View history
- [x] De-dupe repeated URL visits in persisted history
- [x] Sort history newest-first
- [x] Group history by day
- [x] Search history by title, URL, and hostname
- [x] Tokenized history search
- [x] Multi-select history rows
- [x] Open selected history rows
- [x] Delete selected history rows
- [x] Select visible search results
- [x] Select a full day group
- [x] Confirm bulk delete before removal
- [x] Keyboard and range-selection shortcuts
- [x] Save bookmarks
- [x] Toggle bookmarks from the toolbar star
- [x] View bookmarks
- [x] Search bookmarks by title, URL, hostname, and tag
- [x] Add and remove bookmark tags
- [x] Filter bookmarks by tag
- [x] Filter tagged and untagged bookmarks
- [x] Multi-select bookmark rows
- [x] Delete selected bookmarks
- [x] Select visible bookmark results
- [x] Confirm bulk bookmark delete before removal
- [x] Keyboard and range-selection shortcuts

### 0.6 — Window and Tab Management

- [ ] Drag tabs to reorder
- [ ] Detach tab into a new window
- [ ] Move tab between windows
- [ ] Close window when its last tab closes
- [ ] Preserve per-window active tab state

### 0.7 — Downloads

- [ ] Track completed downloads
- [ ] Add `nimlo://downloads`
- [ ] View downloads newest-first
- [ ] Persist downloads metadata
- [ ] Open downloaded files
- [ ] Reveal downloads in Finder
- [ ] Remove or clear download records

### 0.8 — Content Blocking

- [ ] Research uBlock Origin capabilities and filter-list behavior
- [ ] Add URL-level blocking hooks before navigation/request load where WebKit allows
- [ ] Support common filter lists such as EasyList/EasyPrivacy-style network filters
- [ ] Add local filter list storage and update flow
- [ ] Add per-site allow/block controls
- [ ] Add a basic content-blocking settings page
- [ ] Investigate cosmetic filtering feasibility in `WKWebView`
- [ ] Investigate advanced dynamic filtering and per-site firewall scope

### 0.9 — Private Mode UX

- [x] Nonpersistent WebKit data store by default
- [x] Private mode config can disable history persistence
- [x] Private navigation events are not recorded in history
- [x] No session restore persistence yet
- [ ] Private tab or private window distinction
- [ ] Open private tab or private window UI
- [ ] Clear visual private mode indicator

### 1.0 — Settings

- [ ] Default search engine
- [ ] Homepage/start page
- [ ] Download directory
- [ ] Theme preference
- [ ] Private/Incognito behavior
- [ ] Content blocking preferences
- [ ] Data management controls

## Non-Goals for the First Version

Nimlo will not initially include:

- A custom rendering engine
- A custom JavaScript engine
- Browser extensions
- Account sync
- Cloud services
- AI assistant features
- Ad monetization
- Full browser sandboxing
- Full cross-platform parity

The goal is to ship a useful lightweight browser shell first.

## Long-Term Goals

Future directions will include:

- Reader mode
- RSS support
- Local history search
- Tracker blocking
- Import/export bookmarks
- Experimental Zig-native HTML/CSS renderer
- Cross-platform builds
- Minimal extension-like scripting, only after a security model exists

## Development

Current tools:

- Zig
- macOS
- AppKit
- WebKit

Run the app:

```bash
zig build run
```

Build the macOS app bundle:

```bash
zig build bundle
```

Run tests:

```bash
zig build test
```

## Repository Layout

```text
nimlo/
├── README.md
├── LICENSE
├── build.zig
├── docs/
│   └── SPECS.md
├── src/
│   ├── main.zig
│   ├── app/
│   ├── browser/
│   ├── webview/
│   ├── storage/
│   ├── downloads/
│   ├── privacy/
│   ├── ui/
│   └── experimental_engine/
└── assets/
```

## Contributing

Nimlo is intended to be open source and contributor-friendly.

Good first areas will likely include:

- URL parsing tests
- Search engine routing
- History storage
- Start page design
- Documentation
- Platform setup notes

## License
- MIT for maximum simplicity

## Name

**Nimlo** is short, friendly, and lightweight. It suggests nimble movement through the web without sounding corporate or heavy.

## Tagline

Browse lightly.
