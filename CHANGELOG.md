# Changelog

All notable changes to SkuGatherRoute ("GatherMate2 SKU Access") are documented here.

## [Unreleased] — 1.11.0

### Added
- **Multi-select type picker**, alongside the existing "Choisir un type" (single type, starts immediately): "Choisir plusieurs types" opens a checklist — every type present nearby, each toggled on/off individually (label reads "sélectionné"/"non sélectionné"), plus "Tout sélectionner"/"Tout désélectionner" and a "Démarrer avec la sélection (N)" action that only starts once at least one type is checked. Requested directly: "pouvoir activer quels sont les minerais qui peuvent être mis sur le trajet qu'on lance et pas juste en sélectionner qu'un seul." Selection is per-category (mining/herb kept separate) and session-only (not saved across reload/login, same as the navigation-mode choice) — stale picks from a previous zone are dropped automatically if that type is no longer present here.
- The checklist refreshes in place after every toggle (cursor stays on the same entry) using the same list-rebuild mechanism (`SkuGenericMenuItem.OnUpdate`) already proven in SkuBagnonBridge's post-transfer refresh — arrow-key navigation position is preserved across repeated toggles instead of snapping back to the top of the list each time.

## [1.10.1]

### Fixed / diagnostic
- `SelectPlainWaypoint` now always logs which waypoint it selected and why — previously it only logged the automatic-fallback case, so a normal advance in "Waypoint simple" mode (called directly on every route advance) left zero trace, making a "stuck after arrival" report impossible to confirm or refute from the log.
- `FinishCurrentTarget`'s call into `AdvanceToTarget` (advancing to the next-closest node once one finishes) is now `pcall`-guarded and logs any error instead of letting it propagate silently.

## [1.10.0]

### Fixed
- **Stopped this addon from contributing to a Sku minimap-position glitch.** Sku's own `MinimapScanFast` fallback (the only scan method that works on this client — see 1.8.0) shrinks the real Minimap frame to 15×15px, moves it under the cursor, and restores its size/position/alpha about 0.1s later. That restore step isn't fully guarded inside Sku's own code, so a rare internal error can leave the real minimap stuck shrunk/moved on screen. This addon requesting its own scans on top of Sku's already-frequent passive ones made that rare failure noticeably more likely to be hit, purely from the added volume. `CheckNodePresence` no longer requests any scan of its own — presence confirmation relies entirely on ambient results (Sku's own passive scanner, or a manual Ctrl+Shift+R), with a 12-second time-based give-up instead of the old miss-counting one. (`CheckMinedAndAdvance` — confirming a resource is actually gone once at the node — still requests its own scans; there's no ambient substitute for a *negative* confirmation, but that only runs in the last 1 yard of approach, a far narrower window.)

### Added
- **Minimap position save/restore**, under each category's menu (Minicarte): "Enregistrer la position actuelle" saves a snapshot of the minimap's own position/scale/parent; "Restaurer la position enregistrée" puts it back — a direct, on-demand fix for the glitch above if it happens anyway (Sku's own passive scanner keeps running regardless of anything this addon does). Deliberately manual only, no auto-save/auto-fix, so a save can never accidentally capture the minimap mid-glitch.

## [1.9.1]

### Fixed / diagnostic
- `TryOpportunisticSwitch` now logs its own reasoning every time it's called, even when it declines to switch (no matching route node, or the improvement is under the threshold) — previously it only logged an actual switch, making "why didn't it switch to the one I just found" impossible to diagnose from the log alone.
- Throttled this addon's own on-demand presence scans to at most once every 2 seconds (was every 0.15s tick). They almost never succeed anyway (see 1.8.1), and requesting one that often mostly just holds Sku's own shared scan busy-lock more, which can silently block a manual scan (Ctrl+Shift+R) or an ambient passive hit — both far more likely to actually succeed — from running at that exact moment.

## [1.9.0]

### Added
- Navigation mode choice, per category menu (Route de minage / Route d'herbes → Mode de navigation): "Route précise" (default, unchanged — real close-route pathfinding via Sku's own metaroute engine) or "Waypoint simple" (skips the path search entirely, always a plain direct waypoint to each node). Useful when the close-route graph is sparse for the zone being farmed, or when the extra path-search cost per node isn't worth it.

## [1.8.1]

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
