# SkuGatherRoute (aka "GatherMate2 SKU Access")

Optional companion addon for **[Sku](https://github.com/ZenqFR/Sku-WoW-Addon-TBC)** (a screen-reader/accessibility addon for World of Warcraft, TBC Classic) that turns **GatherMate2**'s recorded mining and herb node locations into voice-guided, step-by-step farming routes.

GatherMate2's own options panel (tabs, multiselect lists, an "Import" button) is a standard Blizzard/AceConfig settings tree that isn't usable with a screen reader. This addon reproduces everything needed — importing data, building a route, navigating it, skipping bad nodes — entirely from inside Sku's own accessible menu (`Shift+F1` → "Route de minage" / "Route d'herbes"), without modifying Sku or GatherMate2 themselves.

## What it does

- **Real close-route navigation** — each node is visited via Sku's own metaroute/pathfinding engine (the same feature behind Shift+F9 → a waypoint → "Nahe Routen"), not a straight-line beacon. Falls back to a direct waypoint only where Sku's path network has no coverage.
- **Live nearest-neighbor ordering** — after each node, the closest remaining one is picked fresh from the player's actual position (`SkuNav:GetClosestWaypointFromBaseName`), adapting in real time rather than following a fixed precomputed order.
- **Presence check before committing** — once within a configurable range (25/50/75/100m, default 50m) of a node, checks via Sku's own minimap-blip scanner whether the resource is actually still there and skips ahead immediately if not, instead of wasting the travel time.
- **Guaranteed manual skip** — "Sauter ce minerai" menu entry, plus a dedicated keybind (default `Ctrl+Shift+N`) that abandons the current node immediately, independent of navigation mode.
- **Stuck detection, based on actual movement** — announces a warning if the player is moving but has barely displaced at all over 15 seconds (e.g. blocked by terrain), since Sku's distance math has no elevation awareness and can't detect that on its own. Measures real player displacement, not distance-to-target — a real close route can legitimately curve away from the final target for a while (around a mountain, through a pass) without that meaning anything is wrong.
- **Final-position refinement from the live minimap, and an automatic short reroute** — once close enough to see the resource's own minimap blip, its position is compared against GatherMate2's stored coordinate (which can simply be recorded slightly off) using the same live-scan math behind Sku's own Ctrl+Shift+F minimap scan; a noticeable mismatch nudges the final approach point to match what's actually on the minimap right now, and the close route is recomputed fresh from the player's current position for the most direct final stretch. Guarded against a mismatched blip ever relocating the target implausibly close to the player (which would otherwise cause a false early "arrived").
- **Finishes a node only once it's confirmed actually mined** — reaching the stored coordinate is no longer enough by itself; the addon keeps confirming via the live minimap scan until the resource is confirmed GONE (i.e. actually gathered), not just "close enough by GPS." No automatic timeout either — if you choose not to (or can't) gather it, "Sauter ce minerai" always moves on.
- **Clear, distinct voice feedback for every outcome** — "Confirmé, en approche" the moment a node's presence is confirmed, "Atteint" on arrival, "Passé" on a manual skip, "Introuvable, suivant" when it's found absent — no more silent transitions that make a genuine arrival indistinguishable from a wrongly-early one.
- **Mining and herbs** — one shared route engine serves both `GatherMate2MineDB` and `GatherMate2HerbDB`, each with its own menu section.
- **One-click GatherMate2 import** — reproduces GatherMate2's own "Import GatherMate2Data" button from the Sku menu.
- **GatherMate2 minimap-icon toggle** — GatherMate2 draws its own persistent minimap icons at every recorded node regardless of whether it's still there, which defeats the presence check above; this addon can turn those off in one click.
- **Configurable keyboard shortcuts, from Sku's own menu** — a "Raccourcis clavier" submenu (Shift+F1 → Route de minage/d'herbes) lets you assign/clear a key for every action (skip, start mining, start herbs, stop, status) without leaving Sku's accessible menu — no trip through Blizzard's separate Key Bindings panel needed (though that still works too, both read/write the same bindings). Refuses a key already claimed by one of Sku's own shortcuts instead of silently saving a dead binding (Sku applies its own keys through a separate, higher-priority binding layer that a normal keybind can never win against).
- **Remembers recently finished nodes for ~1h** — every node reached, skipped, or found absent is remembered (persisted across a relog) and excluded from the next route scan, so stopping and restarting doesn't re-offer what you just dealt with. Clearable any time from the menu.
- **Fully translated (French/English/German)** — every spoken line and menu label follows the WoW client's own language automatically, including the ore/herb names used for the presence check (these have to match Sku's own minimap-scanner language to work at all — a French-only version of this addon would have silently failed the presence check on a non-French client).
- **`/sgr [all|herb|stop|skip|status|import]`** — slash command for the same actions, for testing or keyboard-only use outside the menu.

## Requirements

- [Sku](https://github.com/ZenqFR/Sku-WoW-Addon-TBC)
- [GatherMate2](https://www.curseforge.com/wow/addons/gathermate2) and its data pack, [GatherMate2 Data](https://www.curseforge.com/wow/addons/gathermate2-data) (needs to have been imported at least once via this addon's own "Importer les données GatherMate2" menu entry)

## How it works

- Toggle from Sku's own **Features** menu (Local → Settings → Module → Features → "GatherMate2 SKU Access"). Inert with zero effect if GatherMate2 isn't installed.
- Converts GatherMate2's `(uiMapId, x, y)` node coordinates to Sku's own waypoint format (`SkuNav:GetAreaIdFromUiMapId` + `C_Map.GetWorldPosFromMapPos`, the same conversion Sku's own death-recovery code uses), registers each node as a temporary Sku waypoint, and drives navigation between them with a faithful reproduction of Sku's own close-route search algorithm.
- Ships a self-diagnostic log (`/sgrlog`) and a `SkuGatherRouteLog` SavedVariable, so its own behavior can be inspected without needing to reproduce a bug live.

## Status

Built and tested for a single user's own setup (TBC Classic Anniversary realms). Not submitted upstream to Sku — kept as a separate, optional companion addon.

---

Built with [Claude Code](https://claude.com/claude-code).
