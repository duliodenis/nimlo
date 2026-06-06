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

### 0.5 — Bookmarks and History

- [ ] Save bookmarks
- [ ] View bookmarks
- [ ] Remove bookmarks
- [ ] Save local browsing history
- [ ] View history

### 0.6 — Settings

- [ ] Default search engine
- [ ] Homepage/start page
- [ ] Download directory
- [ ] Theme preference

### 0.7 — Private Mode

- [x] Nonpersistent WebKit data store by default
- [x] No history persistence yet
- [x] No session restore persistence yet
- [ ] Private tab or private window distinction
- [ ] Clear visual private mode indicator

### 1.0 — Lightweight Daily Browser Shell

- Stable navigation
- Tabs
- Bookmarks
- History
- Settings
- Downloads
- Private mode
- Local-first data
- No telemetry
- No ads

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

## Long-Term Ideas

Future directions may include:

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
- Bookmark storage
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
