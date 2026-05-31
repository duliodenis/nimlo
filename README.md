# Nimlo

A lightweight, open-source browser built in Zig for fast, private, user-controlled web navigation.

## About
Nimlo is an experimental modern browser project focused on simplicity, speed, and the old feeling of exploring the web without clutter, ads, forced accounts, or unnecessary AI features.

The first version is intentionally modest: a clean browser shell written primarily in Zig that uses the system WebView for page rendering. Over time, Nimlo can grow its own Zig-native browser components around navigation, storage, privacy, history, bookmarks, downloads, and eventually an experimental rendering engine.

## Project Status

Nimlo is in the earliest planning and prototyping stage.

Current goal:

> Build a minimal desktop browser that opens a window, loads a page, and supports basic navigation.

This is not yet a production browser and should not be treated as a secure replacement for Chrome, Safari, Firefox, or Edge.

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

- Launch from `zig build run`
- Open a desktop window
- Embed a system WebView
- Load a default start page
- Load a typed URL

### 0.2 — Basic Browser Controls

- Address bar
- Back
- Forward
- Reload
- Stop loading
- Page title updates

### 0.3 — Tabs

- New tab
- Close tab
- Switch tabs
- Independent page state per tab

### 0.4 — Bookmarks and History

- Save bookmarks
- View bookmarks
- Remove bookmarks
- Save local browsing history
- View history

### 0.5 — Settings

- Default search engine
- Homepage/start page
- Download directory
- Theme preference

### 0.6 — Private Mode

- Private tab or private window
- No history persistence
- No session restore persistence
- Clear visual private mode indicator

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

Requirements are still being finalized.

Expected tools:

- Zig
- Native system WebView layer
- Platform-specific dependencies as needed

Eventually, the project should run with:

```bash
zig build run
```

## Repository Layout

Planned structure:

```text
nimlo/
├── README.md
├── SPEC.md
├── LICENSE
├── build.zig
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
├── assets/
├── tests/
└── docs/
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

License not chosen yet.

Recommended options:

- MIT for maximum simplicity
- Apache-2.0 for stronger patent language
- MPL-2.0 if the project wants browser-style file-level copyleft

## Name

**Nimlo** is short, friendly, and lightweight. It suggests nimble movement through the web without sounding corporate or heavy.

## Tagline

Browse lightly.
