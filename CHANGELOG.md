# Changelog

All notable changes to SkuGatherRoute ("GatherMate2 SKU Access") are documented here.

## [Unreleased] — 1.8.1

### Fixed
- **Root-caused the remaining presence-detection unreliability from 1.8.0.** The diagnostic logging added in that release confirmed every one of this addon's own on-demand scans came back with literally nothing found — not a name mismatch, a total miss. Traced to Sku's own `MinimapScanFast` fallback: it only re-centers the real mouse cursor onto the minimap once per session, then assumes it stays there — ordinary mouse movement during play breaks that within seconds, which is exactly why a ticker-triggered scan (unrelated to wherever the mouse actually is) almost never succeeds, while Sku's own occasional passive "notify on resources" hits still do, by coincidence.
- This addon can't fix that mouse-drift quirk in Sku itself, so instead of only listening for the result of scans it explicitly requested, it now also treats a matching **ambient** scan result — e.g. Sku's own passive notifier succeeding on its own — as a valid presence confirmation for the current target. Directly addresses "quand j'ai une notif me disant que y'en a un à proximité ça devrait switch dessus directement": every successful detection is now used, not just the ones this addon happened to trigger itself.
- Presence confirmation is still not guaranteed on any given approach (it depends on Sku's own scan succeeding at all, still probabilistic) — deliberately did not try to force-recenter the player's real mouse cursor to work around it, since that would be a disruptive side effect for a background service running every 0.15s.

## [1.8.0]

### Fixed
- **Root-caused and fixed the presence/mined-confirmation scan never finding anything, for every resource type, 100% of the time.** The addon used to call `SkuCore.MinimapScanner:MinimapScanChildFrames()` directly. Sku's own source documents that this fast child-frame scan does not work on Anniversary/Classic clients at all — native resource blips aren't addressable child frames there. Sku itself only works because `MinimapScanFast()` falls back to a slower cursor-positioning trick when the fast path finds nothing. This addon now calls the real `MinimapScanFast()` entry point and resolves asynchronously through the same `MinimapScanFastStop` hook used for the opportunistic-switch feature, instead of the broken fast path directly.
- As a consequence, removed `RefineTargetPositionFromBlip` (the "correct the final approach point from the live minimap" feature, added in 1.4.0): the only scan path that actually works on this client exposes a resource name only, never a position, so this feature could never have worked here and was quietly dead code.

## [1.7.1] — Diagnostic build
- Added temporary diagnostic logging to `CheckNodePresence` (zoom value before/after forcing zoom 0, and the full raw list of blips found on a miss) to investigate a 100%-miss presence-check report. Superseded by the 1.8.0 fix above; the diagnostic logging has been removed.

## [1.7.0]
### Added
- Opportunistic switch to a resource Sku's own passive "notify on resources" scanner detects mid-route: if a remaining route node of the same name is meaningfully closer (20+ yards) than the node currently being approached, the close route switches to it on the spot (8s cooldown to avoid flapping between near-equidistant nodes).

## [1.6.0]
### Changed
- A node is now only finished once the resource is confirmed actually GONE from the live minimap scan, not just once the player's coordinates match the stored position — no more advancing past a node that's still genuinely there.
- The close route automatically recomputes (silently) the moment presence is confirmed, for the shortest possible final approach.

## [1.5.0]
### Added
- Distinct voice feedback for every route-advance outcome ("Confirmé, en approche" / "Atteint" / "Passé" / "Introuvable, suivant") — previously some outcomes were silent.
### Fixed
- Hardened the (now-removed, see 1.8.0) position-refinement feature against a rare false-positive minimap blip match that could otherwise relocate a target implausibly close to the player.

## [1.4.1]
### Changed
- Raised the (now-removed, see 1.8.0) position-refinement threshold from 5 to 10 yards — 5 yards was under 2 minimap pixels, too close to ordinary measurement noise.

## [1.4.0]
### Fixed
- Stuck detection false positives: switched from measuring straight-line distance-to-final-target (which can legitimately not decrease on a curved close-route leg) to measuring actual player displacement.
### Added
- (Later removed, see 1.8.0) Final-approach position correction from a live minimap scan.

## [1.3.0]
### Added
- Recent-node memory: nodes reached, skipped, or found absent are remembered for about an hour (persisted across a relog) and excluded from the next route scan.

## [1.2.3]
### Fixed
- False-negative presence checks: forced the minimap to zoom level 0 before scanning (so distant blips render), and required 3 consecutive misses instead of 1 before concluding a node is absent.

## [1.2.1]
### Fixed
- Root cause of every keybind silently doing nothing since the very first release: `LibStub("AceAddon-3.0"):NewAddon(...)` does not expose the addon object as a global, and `Bindings.xml` can only reach globals. Added an explicit `_G.SkuGatherRoute = SkuGatherRoute`.

## [1.2.0]
### Fixed
- Critical localization bug: the presence check always compared against a hardcoded French ore/herb name, which would never match on a non-French client. Resource names are now resolved per-client-language the same way Sku itself resolves them.
### Added
- "Raccourcis clavier" submenu (Shift+F1) to assign/clear keybinds for every action from Sku's own accessible menu.

## [1.1.0]
- First public release, as "GatherMate2 SKU Access": voice-guided mining routes from GatherMate2 data, real close-route navigation via Sku's own metaroute engine, dedicated skip keybind, presence check before committing to a node, mining and herb support.
