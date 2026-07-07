# Content Blocking Plan — Milestone 0.8

Step-by-step plan for README milestone "0.8 — Content Blocking". Written for
handoff: each phase lists its goal, the work, the files, and an exit gate.
Phases B–D are pure shared-Zig and can proceed in parallel with anything;
platform phases (F+) depend on them.

Companion docs: `README.md` (checklist), `docs/SPECS.md` (product spec),
`docs/WINDOWS_PORT.md` (the Windows track this must stay compatible with).

## Scope

In (maps to the README 0.8 checkboxes):

- Research uBlock Origin capabilities and filter-list behavior → **Phase A**
- URL-level blocking hooks before navigation/request load → **Phases D, F**
- EasyList/EasyPrivacy-style network filters → **Phases B, C**
- Local filter list storage and update flow → **Phase E**
- Per-site allow/block controls → **Phase G**
- Basic content-blocking settings page → **Phase H**
- Investigate cosmetic filtering feasibility in `WKWebView` → **Phase I**
- Investigate advanced dynamic filtering / per-site firewall → **Phase J**

Out (explicitly): background/scheduled list updates (1.0 Settings territory),
per-page blocked-request counters on macOS (platform can't observe them — see
below), uBO features with no static-rule equivalent (`redirect=`, `csp=`,
`removeparam`, scriptlet injection), extension APIs.

## Architecture position

Same shape as every other Nimlo feature: **the engine is shared, tested,
platform-neutral Zig; platforms only enforce.**

```
src/blocking/            shared, unit-tested, no platform imports
├── filter.zig           canonical rule model (network + cosmetic + exception)
├── abp_parser.zig       EasyList/ABP syntax → canonical rules
├── matcher.zig          runtime decision engine (URL, type, party → verdict)
└── webkit_rules.zig     canonical rules → WebKit content-blocker JSON

src/storage/
├── filter_lists.zig     list catalog + raw list files + update metadata
└── site_policies.zig    per-site allow/block records (JSONL, inline tests)

src/ui/
└── blocking_page.zig    nimlo://blocking (runtime-rendered HTML, like peers)

assets/filters/          bundled EasyList/EasyPrivacy snapshots + attribution
```

Two enforcement backends consume the same canonical rules:

- **macOS (`WKWebView`)**: rules are *compiled ahead of time* into WebKit's
  content-blocker JSON and attached via `WKContentRuleListStore` — WebKit does
  the per-request matching in-process; Nimlo never sees individual requests.
- **Windows (`WebView2`)**: the shared `matcher.zig` runs *at request time*
  inside the `WebResourceRequested` event. Same rules, opposite evaluation
  model. This is why the matcher must exist even though macOS doesn't call it:
  it is the Windows hot path and the unit-test oracle for the JSON emitter.

## Platform reality check (read before designing anything)

- `WKWebView` has **no per-subresource hook**. `decidePolicyForNavigationAction`
  covers main/subframe navigations only. The only subresource mechanism is
  `WKContentRuleListStore`: JSON rules, compiled async, attached to a
  `WKWebViewConfiguration.userContentController`. Actions: `block`,
  `block-cookies`, `css-display-none`, `ignore-previous-rules`, `make-https`.
  Triggers: `url-filter` (restricted regex), `if-domain`/`unless-domain`,
  `resource-type`, `load-type`. Hard cap ~**150,000 rules per list**; compile
  of a full EasyList takes seconds and the compiled artifact is cached in the
  store by identifier (`lookUpContentRuleListForIdentifier` before recompile).
- Content blockers are **observation-free by design**: macOS cannot count or
  log blocked requests. Any "N blocked" UI is Windows-only or approximate.
- Rule-list changes affect **future loads only** — after toggling, the active
  tab needs a reload (mirror what the user expects from Safari blockers).
- ABP → WebKit JSON conversion is **lossy** (regex flavor limits, unsupported
  options like `$popup`, `$websocket` pre-Safari-15 semantics, etc.). The
  emitter must count and report dropped rules, not silently eat them.
- WebView2's `AddWebResourceRequestedFilter` + `add_WebResourceRequested`
  gives true per-request interception (URI, resource context, headers) —
  strictly more capable; the Windows integration is deliberately thin.
- Nimlo's webviews use a **non-persistent data store**, but rule-list compile
  caches live in a separate `WKContentRuleListStore` directory — point it at
  `~/.nimlo/filters/compiled` explicitly (`storeWithURL:`), don't use the
  default store.

## Phase A — Research and capability matrix

Goal: the "Research uBlock Origin" checkbox, produced as a short section
appended to this document, so scope decisions are recorded and the two later
"investigate" phases have a baseline.

1. Catalog uBO capability tiers: static network filtering (blocking +
   exceptions + options), cosmetic filtering (generic/specific element hiding,
   procedural selectors), dynamic filtering (per-site 3p matrix), scriptlets,
   `redirect=`/neutered resources.
2. For each tier: representable in WebKit static rules? representable in a
   runtime matcher (Windows)? → yes/partial/no table.
3. Measure the real lists: rule counts for current EasyList + EasyPrivacy by
   category, share of rules that survive WebKit conversion (prototype the
   counting with a throwaway script; the real emitter comes in Phase D).
4. Decide and record the 0.8 subset: **static network filtering with
   exceptions and per-site allow, EasyList + EasyPrivacy defaults** (expected
   outcome; adjust from data).

Exit gate: capability matrix + measured counts committed to this doc; 0.8
subset signed off.

## Phase B — Canonical filter model and ABP parser

Goal: parse EasyList syntax into a typed rule set. Pure shared code.

1. `src/blocking/filter.zig`: `NetworkRule` (pattern kind: domain-anchored
   `||`, start-anchored `|`, plain substring, separator `^`, wildcards;
   options: resource types, `third-party`/`first-party`, `domain=` include/
   exclude lists, case sensitivity; `is_exception` for `@@`), `CosmeticRule`
   (`##`/`#@#`, domain scoping) — parsed but unused until Phase I, and
   `ParseStats` (kept, dropped, unsupported-by-category).
2. `src/blocking/abp_parser.zig`: line-based parser — comments (`!`), section
   headers (`[Adblock Plus 2.0]`), network rules, cosmetic rules, unsupported
   constructs (procedural `#?#`, scriptlet `##+js(...)`, `$redirect` etc.)
   classified into `ParseStats` rather than erroring. Must chew through the
   real ~100k-line EasyList in well under a second (line loop + slices, no
   allocation per accepted rule beyond the rule storage arena).
3. Tests: fixture-driven — a curated corpus of representative real EasyList
   lines with expected parse results, plus stats accounting over a fixture
   file. Register `blocking` test artifacts in `build.zig` (convention:
   every logic module ships tests).

Exit gate: parser round-trips the curated corpus; parsing a bundled full
EasyList snapshot reports plausible stats in a test; `zig build test` green.

## Phase C — Runtime matcher

Goal: `matcher.zig` answers "should this request load?" — the Windows hot
path and the correctness oracle for everything else.

1. API: `Verdict = allow | block`, from
   `match(request_url, document_url, resource_type, is_third_party)`.
   First/third-party derivation from registrable domains — a pragmatic
   fixed-list-free heuristic first (eTLD+1 by last-two/known-second-level
   labels), with a note that a public-suffix table can slot in later; keep it
   in `web_strings.zig`-style shared code with tests.
2. Indexing for scale (uBO's trick, simplified): tokenize patterns, bucket
   rules by a representative token in a hash map; candidate rules for a URL =
   union of buckets for the URL's tokens (+ tokenless bucket). Target: match
   decision well under a millisecond against full EasyList+EasyPrivacy.
3. Evaluation order: exception (`@@`) rules trump block rules; `domain=` and
   party options filter candidates; per-site policies (Phase G) are applied
   by the caller, not baked into the matcher.
4. Tests: verdict fixtures (URL + context → expected) covering each pattern
   kind and option; a micro-benchmark test guarded to not gate CI on timing.

Exit gate: fixture suite green; benchmark shows index (not linear scan)
behavior; matcher exposed via a tiny CLI-ish test helper is optional but
handy (`zig test` only is fine).

## Phase D — WebKit content-blocker JSON emitter

Goal: canonical rules → `WKContentRuleListStore`-compatible JSON, within
WebKit's constraints. Shared code; macOS only consumes the output.

1. `src/blocking/webkit_rules.zig`: emit `trigger`/`action` objects — pattern
   kinds → WebKit's restricted `url-filter` regex (escape, `||` →
   `^[^:]+://+([^:/]+\.)?` prefix idiom, `^` separator → its character-class
   idiom); options → `resource-type`, `load-type`, `if-domain`/
   `unless-domain`; `@@` exceptions → trailing `ignore-previous-rules` rules.
   Rules that can't be expressed → counted dropped (stats surface in the
   settings page).
2. Enforce the 150k cap with a deterministic priority order (block rules
   before less-important categories; document the order); emit UTF-8 JSON via
   `std.json` writer.
3. Tests: golden JSON for the curated corpus; property checks (every emitted
   regex compiles under WebKit's documented subset — approximated by a
   validator function with its own tests); cap behavior; **cross-check
   against the matcher**: for each fixture verdict, the emitted JSON's
   intended effect must agree (this is the emitter's real spec).

Exit gate: golden + cross-check suites green; conversion stats for the real
snapshots recorded in this doc (feeds Phase A's table).

## Phase E — Filter list storage and update flow

Goal: lists on disk, versioned, updatable on demand; works offline on first
run.

1. Bundled snapshots: `assets/filters/easylist.txt`, `easyprivacy.txt` +
   `assets/filters/README.md` with versions, source URLs, and attribution.
   **Licensing**: EasyList is dual-licensed GPLv3 / CC BY-SA 3.0 —
   attribution required; keep the notice with the snapshots and surface it on
   the settings page. Embed via the existing asset-wrapper pattern
   (`start_page_asset`-style anonymous import; ~2 MB embedded is acceptable)
   and write out to the data dir on first run.
2. `src/storage/filter_lists.zig`: catalog of lists (id, name, source URL,
   enabled, rule stats, last-updated, etag) persisted as
   `~/.nimlo/filters/lists.jsonl` + raw list text files alongside; inline
   tests like the other stores.
3. Update flow ("Update now" from the settings page, no scheduler in 0.8):
   fetch with `std.http.Client` (Zig 0.16 std TLS). **Risk note:** if std TLS
   proves unreliable against the CDNs, fall back to the platform layer
   (NSURLSession via the objc bridge on macOS / WinHTTP on Windows) behind a
   tiny `fetchUrl` seam — decide only if the risk materializes. Conditional
   GET via etag/If-Modified-Since; parse+validate the download **before**
   replacing the on-disk list (a garbage download must never brick blocking);
   then reparse, re-emit, recompile, and republish state.
4. Fetching must not block the UI thread: do the network+parse on a
   `std.Thread`, marshal completion back to the main thread the same way the
   platform marshals other async completions (macOS:
   `performSelectorOnMainThread`/dispatch; Windows: `PostMessageW` custom
   message). The engine mutates state only on the main thread.

Exit gate: first run writes snapshots and loads them; update flow round-trips
against the real EasyList URL manually; corrupted-download test proves the
old list survives.

## Phase F — macOS enforcement

Goal: the compiled rules actually block, on every webview, in every window.

1. `webview2`-bridge equivalent for WebKit: extend the objc bridge use in
   `src/webview/webview_macos.zig` / `src/ui/chrome_macos.zig`:
   `WKContentRuleListStore storeWithURL:` (at `~/.nimlo/filters/compiled`),
   `lookUpContentRuleListForIdentifier:completionHandler:`,
   `compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:`
   (async — completion blocks need the existing block-helper pattern used for
   WKDownload delegates; follow whatever chrome_macos already does for
   ObjC blocks).
2. Attach at webview creation: `createNativeWebView` adds the compiled lists
   to the configuration's `userContentController` (`addContentRuleList:`).
   Keep a process-wide registry of live rule lists so toggles can
   `removeContentRuleList:`/`addContentRuleList:` across **all** webviews in
   **all** windows (iterate the existing per-window webview registries).
3. Identifier scheme = list id + content hash, so unchanged lists hit the
   compile cache and startup does zero compilation in the steady state.
4. Startup order: begin lookup/compile as soon as the app controller has the
   data dir — before the first webview if cached, without blocking first
   paint if not (attach when ready; a first page that raced the compile is
   unblocked until its next navigation, which matches Safari blocker
   behavior; note it in the settings page copy).
5. Navigation-level fallback stays: `decidePolicyForNavigationAction` also
   consults the shared matcher for main-frame URLs (cheap, and it is the only
   macOS-observable blocking signal — log it for the self-test).

Exit gate: manual pass on ad-heavy sites with/without lists enabled shows the
difference; `NIMLO_BLOCKING_TEST` (below) green; toggling a list affects a
fresh navigation in every open window.

## Phase G — Per-site allow/block controls

Goal: "blocking off for this site" (and "extra-block this site") that
survives restarts.

1. `src/storage/site_policies.zig`: JSONL records (host, policy allow|block,
   added-at), same store conventions and tests as bookmarks/history.
2. Semantics: `allow` disables network blocking for documents on that host;
   `block` reserved as a stricter placeholder (0.8 may ship allow-only if
   block has no clear meaning yet — decide in Phase A).
3. macOS enforcement options, in preference order — **verify empirically,
   this is the phase's research risk**: (a) a separate tiny always-attached
   "site exceptions" rule list containing `ignore-previous-rules` rules with
   `if-domain` per allowed site — works only if `ignore-previous-rules`
   applies across earlier-attached lists (cross-list semantics are not
   clearly documented); (b) fallback: recompile the main lists with the
   exception rules appended (compile cache keyed on content hash makes this
   a few seconds once per change). Windows needs neither: the matcher caller
   checks the policy store first.
4. Sink/route plumbing (pattern match the existing ones exactly):
   emit-only routes `https://nimlo.internal/blocking/site/allow?host=…` /
   `remove?host=…` dispatched in `src/ui/internal_routes.zig`, new
   `on_blocking_*` EventSink callbacks, handled in `browser.zig` beside the
   bookmark handlers, persisted via a `core.enableContentBlocking(paths)`
   enable call in `app.zig` mirroring `enableHistoryPersistence`.
5. Chrome affordance: minimal for 0.8 — a shield toolbar toggle emitting the
   allow/remove event for the active tab's host, with pressed-state from
   `TabSnapshot` (add an `is_site_allowed` field — snapshot extension is a
   portable-core change, fine). Full UI lives in the settings page.

Exit gate: allow a site → its ads load after reload → remove → blocked again;
state survives restart; works from both the shield and the settings page.

## Phase H — `nimlo://blocking` settings page

Goal: the "basic content-blocking settings page" checkbox.

1. `src/ui/blocking_page.zig`, runtime-rendered like history/bookmarks/
   downloads pages: master on/off, per-list toggles with rule counts +
   dropped-rule counts + last-updated, "Update now" per list and global,
   per-site policy table with remove buttons, attribution/licensing footer.
   Windows additionally gets a session blocked-request counter (macOS copy
   explains why it can't).
2. Routing: `nimlo://blocking` branch in `browser.zig`'s internal-page loader
   (beside the existing `nimlo://downloads` branch); action URLs
   (`blocking/toggle?list=…`, `blocking/update`, `blocking/site/…`) through
   `internal_routes.dispatch` — all emit-only, no new platform `Decision`
   variants expected.
3. Page re-render after mutations via the existing
   `on_internal_page_reload_requested` flow.
4. Tests: `src/blocking_page_tests.zig` following the `*_page_tests.zig`
   pattern (render with fixture state, assert escaping and action URLs), plus
   new `internal_routes` dispatch tests.

Exit gate: full loop works — toggle list on page → reload a tab → behavior
changes → state reflected on page after re-render; page tests green.

## Phase I — Investigation: cosmetic filtering in WKWebView

Deliverable: findings appended to this doc + go/no-go for shipping basic
element hiding in 0.8.x.

Questions to answer with prototypes: do `css-display-none` rules generated
from `##` selectors fit alongside network rules under the 150k cap (cosmetic
rules dominate EasyList by count — likely needs the cap-priority order from
Phase D or a separate list); performance impact of tens of thousands of
selector rules; generic vs `domain##` scoping fidelity; `#@#` exceptions via
`ignore-previous-rules`. Windows note: cosmetic filtering there would be
CSS/JS injection via `AddScriptToExecuteOnDocumentCreated` — prototype only
after macOS answers are in.

## Phase J — Investigation: dynamic filtering / per-site firewall

Deliverable: findings appended to this doc; expected recommendation is
**defer past 1.0** and the write-up should confirm or refute it.

uBO's dynamic matrix (per-site rules like "block all 3p frames on host X")
requires per-request decisions with document context. Windows can do it
(WebResourceRequested has both). macOS cannot with static rule lists short of
per-site rule-list recompiles (`if-top-url` triggers get partway — evaluate).
Record the capability asymmetry and what a Windows-first dynamic mode would
mean for parity policy before committing to anything.

## Verification strategy

- Every shared module: unit tests registered in `build.zig`, running on all
  hosts, part of the standard gate (`zig build test`, `check-portable`,
  `check-windows`, macOS `zig build`).
- **Self-test hook** (`NIMLO_BLOCKING_TEST=1`, wired in `runEventLoop` beside
  the existing hooks): load a local HTML page via `loadHtml` that `fetch()`es
  a URL matching a bundled always-blocked test rule (e.g.
  `||nimlo-blocking-selftest.invalid^`) and an allowed control URL, then
  reports through the page title (`BLOCKED-OK` / `FAIL`) — title flows
  through the existing navigation events, so the result is observable in
  logs on both platforms despite macOS's no-callback rule engine. Run it in
  CI on macOS (and Windows once the port reaches Phase 5 of
  `docs/WINDOWS_PORT.md`).
- Manual pass list: a handful of ad-heavy reference sites checked with lists
  on/off/site-allowed, before each phase-gate sign-off.

## Windows parity note

Do not implement Windows enforcement inside this milestone unless the port
has already reached `docs/WINDOWS_PORT.md` Phase 5; instead, keep the seam
honest: everything except Phase F and the macOS half of Phase G lands in
shared code the Windows track consumes later (matcher-in-
`WebResourceRequested` + policy-store check + script-injection stub). Add a
"Phase 8 — Content blocking" section to `docs/WINDOWS_PORT.md` when this
milestone ships on macOS.

## Definition of done (0.8)

Every README 0.8 checkbox true on macOS: research documented here (A);
navigation- and request-level blocking live (D/F); EasyList+EasyPrivacy
parsing, conversion, and enforcement working with dropped-rule accounting
(B/C/D); lists stored locally with a working manual update flow that
survives bad downloads (E); per-site allow persisted and enforced (G);
`nimlo://blocking` shipping (H); both investigations written up with
go/no-go outcomes (I/J). All standard build gates green throughout; the
blocking self-test green in CI.
