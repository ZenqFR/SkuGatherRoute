-- SkuGatherRoute -- optional local companion addon.
-- Turns GatherMate2's recorded node databases into voice-guided farming
-- routes through Sku, reachable from Shift+F1 -> "Route de minage" (mining)
-- and "Route d'herbes" (herbs, 2026-08-18, secondary priority) -- both
-- appended at the very end of the root menu, per the user's request. The two
-- share one route engine (RESOURCE_CATEGORIES descriptor below) -- reading
-- the mining explanations in this header applies equally to herbs unless
-- said otherwise.
--
-- ---------------------------------------------------------------------------
-- HOW THIS WORKS (read this before touching the route logic)
--
-- 1. DATA SOURCE: GatherMate2's own SavedVariables -- GatherMate2MineDB for
--    mining, GatherMate2HerbDB for herbs (RESOURCE_CATEGORIES.dbGlobal picks
--    the right one) -- shaped identically for both, exactly like GatherMate2/
--    GatherMate2.lua's GatherMate:AddNode leaves them:
--        GatherMate2MineDB[uiMapId][encodedXY] = nodeTypeId
--    uiMapId is a standard Blizzard map id (GatherMate2 is built on
--    HereBeDragons/C_Map, same id space Sku itself uses). encodedXY packs a
--    0..1 map-fraction (x,y) pair; decoded with the EXACT inverse of
--    GatherMate2's own GatherMate:EncodeLoc (GatherMate2/GatherMate2.lua):
--        encode(x,y) = floor(x*10000+0.5)*1000000 + floor(y*10000+0.5)*100
--        decode(id)  = floor(id/1000000)/10000, floor(id%1000000/100)/10000
--    Replicated locally below (DecodeGatherMateCoord) rather than calling
--    into GatherMate2 -- this is just arithmetic, no need for a dependency
--    on GatherMate2's internals beyond reading its SavedVariable.
--
--    GatherMate2 only POPULATES this from data pack imports or the player's
--    own mining if the user has actually run the import (GatherMate2's own
--    options -> Import tab, or "Auto Import" toggled on there) -- that is a
--    one-time in-game settings action for the user, not something this addon
--    does for them.
--
-- 2. COORDINATE CONVERSION: a GatherMate2 node is (uiMapId, xFrac, yFrac).
--    SkuNav:SetWaypoint (SkuNav/Core.lua) wants (contintentId, areaId,
--    worldX, worldY). The conversion below is copied from how Sku's OWN code
--    does exactly this in SkuNav/Core.lua (SkuNav:ProcessPlayerDead uses the
--    identical C_Map.GetWorldPosFromMapPos + GetAreaData pattern):
--        local tAreaId = SkuNav:GetAreaIdFromUiMapId(uiMapId)
--        local _, worldPos = C_Map.GetWorldPosFromMapPos(uiMapId, CreateVector2D(x, y))
--        local worldX, worldY = worldPos:GetXY()
--        local contintentId = select(3, SkuNav:GetAreaData(tAreaId))
--    (Sku really does spell it "contintentId" throughout SkuNav -- kept
--    verbatim so this addon's calls match its field names exactly.)
--
-- 3. NAVIGATION: [rewritten 2026-08-17, per "pas à pas, en mode close route,
--    pas en mode waypoint"] Each node is visited via a REAL close route
--    (metaroute) -- the exact same feature reachable by hand through Shift+
--    F9 -> a waypoint -> "Nahe Routen" (SkuNav/Options.lua), which follows
--    Sku's own pre-built path network instead of a straight-line beacon.
--    StartCloseRouteTo (below) reproduces that computation directly instead
--    of driving it through the menu, since the target here is picked
--    programmatically. When no graph coverage is found near the player or
--    the target, it falls back to a plain SkuNav:SelectWP for that one node
--    -- still fully functional, just a straight beacon instead of a real
--    path. Order of visits across nodes is still nearest-first, live and
--    adaptive: SkuNav:GetClosestWaypointFromBaseName (the same primitive
--    Sku's own SKU_KEY_SELECTNEXTBASEWAYPOINT keybind uses) picks the next
--    node fresh from the player's actual position every time one finishes,
--    rather than following a precomputed order -- a waypoint named "Route
--    de minage;7" has base name "Route de minage" (everything before the
--    first ";" -- SkuNav:StripBaseNameFromWaypointName), which is how they
--    all get found as one family.
--
--    "Arrival" at the current target and the 50m presence check are both
--    driven by this addon's own 0.15s ticker (WatchRouteProgress) polling
--    SkuNav:GetDistanceToWp directly against the CURRENT target -- not by
--    watching SkuSettings:Sub("SkuNav").selectedWaypoint, which cycles
--    through every intermediate path waypoint while a close route is under
--    way and so cannot tell "reached one hop" from "reached the actual ore
--    node". Manual skip is its OWN dedicated action (SkuGatherRoute:
--    SkipCurrentTarget, see its own comment) rather than piggybacking on
--    Sku's native SKU_KEY_MOVETONEXTWP/SkuNav.MoveToWp -- that flag turned
--    out to be inherently racy for any OUTSIDE code to poll (Sku's own
--    OnUpdate driver resets it unconditionally on roughly every 0.1s tick,
--    which can beat a slower addon ticker to it) and, even when caught,
--    only steps ONE path hop per press rather than abandoning the current
--    target -- confirmed unreliable by the user's own testing.
--
--    Each node is deleted from SkuNav the moment it's finished (reached,
--    skipped, or found absent), so it can never be re-offered and a
--    cancelled/restarted route cleans up completely instead of leaking
--    waypoints. Deleting on completion is used instead of Sku's own
--    trackVisited/waypointWasVisited setting deliberately -- that only
--    works if the user happens to have it enabled, and it can time-expire
--    (SkuNav/Visited.lua); an outright delete cannot silently fail either
--    way.
-- ---------------------------------------------------------------------------

local ADDON_NAME = ...

---------------------------------------------------------------------------------------------------------------------------------------
-- Self-diagnostic log -- SAME pattern as SkuBagnonBridge/Core.lua (proven
-- across that addon's own debugging cycle), including the pre-restoration
-- buffering caveat: WoW swaps the real SavedVariable table in AFTER this
-- file finishes executing, so anything logged before that point is buffered
-- locally and flushed on this addon's own ADDON_LOADED.
local tLogBuffer = {}
local tLogFlushed = false

local function Log(aFmt, ...)
	local tOk, tMsg = pcall(string.format, aFmt, ...)
	if not tOk then tMsg = tostring(aFmt) end
	local tLine = "[" .. ((date and date("%H:%M:%S")) or "?") .. "] " .. tMsg
	if tLogFlushed then
		table.insert(SkuGatherRouteLog, tLine)
		while #SkuGatherRouteLog > 500 do table.remove(SkuGatherRouteLog, 1) end
	else
		table.insert(tLogBuffer, tLine)
	end
end

local tLogFrame = CreateFrame("Frame")
tLogFrame:RegisterEvent("ADDON_LOADED")
tLogFrame:SetScript("OnEvent", function(self, aEvent, aName)
	if aEvent == "ADDON_LOADED" and aName == ADDON_NAME then
		SkuGatherRouteLog = (type(SkuGatherRouteLog) == "table") and SkuGatherRouteLog or {}
		for _, tLine in ipairs(tLogBuffer) do
			table.insert(SkuGatherRouteLog, tLine)
		end
		tLogBuffer = {}
		tLogFlushed = true
		while #SkuGatherRouteLog > 500 do table.remove(SkuGatherRouteLog, 1) end
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

SLASH_SGRLOG1 = "/sgrlog"
SlashCmdList["SGRLOG"] = function(aMsg)
	aMsg = (aMsg or ""):lower():match("^%s*(.-)%s*$")
	local tLog = (tLogFlushed and SkuGatherRouteLog) or tLogBuffer
	if aMsg == "clear" then
		if tLogFlushed then
			for i = #SkuGatherRouteLog, 1, -1 do SkuGatherRouteLog[i] = nil end
		else
			tLogBuffer = {}
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSkuGatherRoute|r: log efface.")
		return
	end
	local tN = #tLog
	if tN == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSkuGatherRoute|r: aucune entree.")
		return
	end
	local tCount = tonumber(aMsg) or 20
	local tStart = math.max(1, tN - tCount + 1)
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff80c0ffSkuGatherRoute|r: %d entree(s), affichage de %d a %d :", tN, tStart, tN))
	for i = tStart, tN do
		DEFAULT_CHAT_FRAME:AddMessage(tLog[i])
	end
end

-- Labels for the dedicated "skip this ore" keybind (Bindings.xml, see
-- SkipCurrentTarget/InstallDefaultKeybind below) -- read by Blizzard's own
-- Key Bindings panel to show a category header and binding name instead of
-- the raw internal names. Set unconditionally, before the Sku/SkuNav guard
-- below, since Blizzard's UI expects these globals to simply exist.
-- [2026-08-18] Full label set for all 5 keybindable actions (was just the
-- one "skip" binding). Resolved via Sku.deEn right away -- Sku is a hard
-- TOC dependency (## Dependencies: Sku) so it's already fully loaded and
-- executed by the time this file runs, same reasoning already applied to
-- every Sku.deEn call elsewhere in this file. Blizzard's Key Bindings panel
-- reads these as plain globals ONCE at binding-list-build time (no live
-- re-localization), so this is the client's language at first load -- exactly
-- as good as Sku's own BINDING_NAME_SKU_KEY_* labels, which have the same
-- one-shot-at-load characteristic.
local function tBindLabel(aDe, aEn, aFr)
	return (Sku and Sku.deEn and Sku.deEn(aDe, aEn, aFr)) or aFr
end
BINDING_HEADER_SKUGATHERROUTE = tBindLabel("Sku - Abbauroute", "Sku - Gather route", "Sku - Route de minage")
BINDING_NAME_SKUGATHERROUTE_SKIP = tBindLabel("Dieses Vorkommen ueberspringen (naechstes)", "Skip this node (go to next)", "Sauter ce minerai/cette herbe (aller au suivant)")
BINDING_NAME_SKUGATHERROUTE_STARTMINING = tBindLabel("Abbauroute starten (alle)", "Start mining route (all)", "Démarrer : route de minage (tout)")
BINDING_NAME_SKUGATHERROUTE_STARTHERB = tBindLabel("Kraeuterroute starten (alle)", "Start herb route (all)", "Démarrer : route d'herbes (tout)")
BINDING_NAME_SKUGATHERROUTE_STOP = tBindLabel("Route stoppen", "Stop route", "Arrêter la route")
BINDING_NAME_SKUGATHERROUTE_STATUS = tBindLabel("Routenstatus ansagen", "Announce route status", "Annoncer l'état de la route")

Log("Core.lua executing. Sku=%s SkuCore=%s SkuNav=%s", tostring(Sku ~= nil), tostring(SkuCore ~= nil), tostring(SkuNav ~= nil))

if not Sku or not SkuCore or not SkuNav then
	Log("ABORT: Sku, SkuCore or SkuNav global missing at file-load time -- addon inert this session.")
	return
end

---------------------------------------------------------------------------------------------------------------------------------------
local SkuGatherRoute = LibStub("AceAddon-3.0"):NewAddon("SkuGatherRoute", "AceConsole-3.0")
Log("AceAddon object created.")

-- [2026-08-18, ROOT CAUSE FIX] AceAddon:NewAddon does NOT expose the created
-- object as a global -- confirmed by reading Libs/AceAddon-3.0/AceAddon-3.0
-- .lua directly: it only stores it in AceAddon's OWN internal registry
-- (self.addons[name]), never touches _G. `local SkuGatherRoute = ...` above
-- is therefore a plain chunk-local upvalue, visible only to closures defined
-- LATER IN THIS SAME FILE (every menu action below correctly resolves it
-- that way) -- but Bindings.xml's <Binding> body is compiled as its OWN
-- separate chunk by the WoW client, with only _G reachable for any name it
-- doesn't declare itself. All 5 of this addon's keybinds
-- (SKUGATHERROUTE_SKIP/STARTMINING/STARTHERB/STOP/STATUS) were therefore
-- ALWAYS evaluating SkuGatherRoute as a nonexistent global (nil) -- a
-- complete no-op -- since day one, NOT a regression from the recent keybind
-- work. (The earlier "confirmed working in-game" read of the skip keybind
-- from SkuGatherRouteLog was a misdiagnosis: SkipCurrentTarget's log line is
-- identical whether reached via the keybind or the always-working "Sauter
-- ce minerai" MENU action, which calls it as a normal same-file closure --
-- the log couldn't actually distinguish the two paths. See this addon's own
-- memory entry for the correction.) Fixed by explicitly publishing the
-- object as a real global right here, once, immediately after creation.
_G.SkuGatherRoute = SkuGatherRoute

-- Shows up as "Route de minage" in Sku's Features on/off menu. Defaults ON
-- (unset = on, Sku's normal rule) -- no forced-default-off here. See
-- SkuBagnonBridge/Core.lua's [2026-08-17, finding #1] comment for exactly
-- why that pattern is a trap: forcing SetModuleEnabled(false) at file-load
-- time disables the AceAddon object before AceAddon's own PLAYER_LOGIN
-- enable pass ever runs, and OnEnable then never fires again that session.
-- IsGatherMatePresent() below already keeps this addon fully inert with no
-- visible effect whenever GatherMate2 isn't installed, so "on by default"
-- is exactly as safe here as it is for every other Sku standalone addon.
SkuCore:RegisterToggleableAddon("SkuGatherRoute", function()
	return "GatherMate2 SKU Access"
end)
Log("Registered as toggleable addon with SkuCore.")

---------------------------------------------------------------------------------------------------------------------------------------
local function IsGatherMatePresent()
	local tIsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if not tIsLoaded then return false end
	return tIsLoaded("GatherMate2") == true
end

local function Announce(aText)
	if SkuOptions and SkuOptions.Voice and SkuOptions.Voice.OutputStringBTtts then
		SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.2)
	else
		print(aText)
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-17] Reachable from the menu itself -- the user cannot operate
-- GatherMate2's own options panel (a standard Blizzard/AceConfig settings
-- tree: tabs, a multiselect, an "Import" button) with a screen reader, so
-- this reproduces exactly what that panel's own "Import GatherMate2Data"
-- button does (GatherMate2/Config.lua, importOptions.args.GatherMateData
-- .args.loadData.func) by calling the SAME underlying functions directly:
--   1. C_AddOns.LoadAddOn("GatherMate2_Data") -- it's LoadOnDemand=1, so
--      nothing in it runs until something asks for it.
--   2. GatherMate2_Data:PerformMerge({Mines = true, Herbs = true}, "Merge",
--      nil) -- confirmed by reading GatherMate2_Data/Tbc/GatherMateData.lua
--      directly: "Merge" style means ADD to the existing DB (GatherMate:
--      ClearDB is only called for style ~= "Merge") -- this never wipes
--      anything the player has already found themselves.
--
-- [2026-08-18] Imports BOTH Mines and Herbs together now that this addon
-- covers both categories (was Mines-only) -- one button primes everything,
-- no need to remember which menu to import from first.
--
-- [2026-08-18] NOT actually idempotent, found by testing: GatherMate2_Data:
-- CleanupImportData() (called at the end of PerformMerge) nils out ALL FOUR
-- raw GatherMateData2*DB globals once consumed, and a LoadOnDemand addon's
-- file body never re-runs once loaded -- so calling this a second time in
-- the same session made MergeMines crash on pairs(nil) (GatherMate2_Data/
-- Tbc/GatherMateData.lua:19). Guarded below: if the raw mining data is
-- already gone, that means an earlier import this session already
-- succeeded (Mines and Herbs are always cleared together), so this is
-- reported as a no-op rather than attempted (and crashing).
local function ImportGatherMateData()
	if not IsGatherMatePresent() then
		Announce(Sku.deEn and Sku.deEn("GatherMate2 nicht geladen", "GatherMate2 not loaded", "GatherMate2 non chargé") or "GatherMate2 non chargé")
		return
	end

	local tLoaded, tReason = C_AddOns.LoadAddOn("GatherMate2_Data")
	Log("ImportGatherMateData: LoadAddOn(GatherMate2_Data) loaded=%s reason=%s", tostring(tLoaded), tostring(tReason))
	if not tLoaded then
		Announce(Sku.deEn and Sku.deEn("GatherMate2Data konnte nicht geladen werden", "GatherMate2Data could not be loaded", "Impossible de charger GatherMate2Data") or "Impossible de charger GatherMate2Data")
		return
	end

	local tGatherMateData = LibStub("AceAddon-3.0"):GetAddon("GatherMate2_Data", true)
	if not tGatherMateData or not tGatherMateData.PerformMerge then
		Announce(Sku.deEn and Sku.deEn("GatherMate2Data-Objekt nicht gefunden", "GatherMate2Data object not found", "Objet GatherMate2Data introuvable") or "Objet GatherMate2Data introuvable")
		Log("ImportGatherMateData: GatherMate2_Data AceAddon object or PerformMerge missing after load.")
		return
	end

	if type(_G.GatherMateData2MineDB) ~= "table" then
		Announce(Sku.deEn and Sku.deEn("Bereits importiert diese Sitzung", "Already imported this session", "Déjà importé pour cette session") or "Déjà importé pour cette session")
		Log("ImportGatherMateData: GatherMateData2MineDB already consumed -- skipping re-import (already done this session).")
		return
	end

	local tOk, tErr = pcall(tGatherMateData.PerformMerge, tGatherMateData, { Mines = true, Herbs = true }, "Merge", nil)
	if not tOk then
		Announce(Sku.deEn and Sku.deEn("Fehler beim Import", "Error during import", "Erreur pendant l'import") or "Erreur pendant l'import")
		Log("ImportGatherMateData: PerformMerge THREW: %s", tostring(tErr))
		return
	end

	local function tCountDB(aGlobalName)
		local tN = 0
		local tDB = _G[aGlobalName]
		if type(tDB) == "table" then
			for _, tZoneDb in pairs(tDB) do
				if type(tZoneDb) == "table" then
					for _ in pairs(tZoneDb) do tN = tN + 1 end
				end
			end
		end
		return tN
	end
	local tMineCount = tCountDB("GatherMate2MineDB")
	local tHerbCount = tCountDB("GatherMate2HerbDB")
	Announce((Sku.deEn and Sku.deEn("GatherMate2-Daten importiert", "GatherMate2 data imported", "Données GatherMate2 importées") or "Données GatherMate2 importées")
		.. " " .. tMineCount .. " " .. (Sku.deEn and Sku.deEn("Erzknoten", "ore nodes", "nœuds de minerai") or "nœuds de minerai")
		.. ", " .. tHerbCount .. " " .. (Sku.deEn and Sku.deEn("Kraeuterknoten", "herb nodes", "nœuds d'herbe") or "nœuds d'herbe"))
	Log("ImportGatherMateData: import complete, %d mining node(s), %d herb node(s).", tMineCount, tHerbCount)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-17] Root cause the user found by testing: GatherMate2 draws its
-- OWN persistent minimap icon at every node coordinate it has ever recorded
-- -- regardless of whether that node is currently really there. The
-- presence check above (CheckNodePresence) reads minimap child frames via
-- Sku's own MinimapScanChildFrames, which cannot tell a live Blizzard
-- resource blip apart from GatherMate2's own icon sitting at the same
-- pixel -- so it was matching GatherMate2's icon and always reporting
-- "present", even for a genuinely depleted node. GatherMate2 itself exposes
-- exactly one relevant setting for this: GatherMate2.db.profile.showMinimap
-- (GatherMate2/Display.lua gates its whole icon-draw/update path on it;
-- GatherMate2/Config.lua's own "Show Minimap Icons" checkbox just flips
-- this same field). Toggled here instead of asking the user to find that
-- checkbox themselves (same accessibility reasoning as ImportGatherMateData
-- above -- GatherMate2's own options panel is not usable with a screen
-- reader). Display:UpdateMaps() is called right after flipping it OFF so
-- already-drawn icons clear immediately rather than lingering until the
-- next unrelated minimap update.
local function ToggleGatherMateMinimapIcons()
	if not IsGatherMatePresent() then
		Announce(Sku.deEn and Sku.deEn("GatherMate2 nicht geladen", "GatherMate2 not loaded", "GatherMate2 non chargé") or "GatherMate2 non chargé")
		return
	end

	local tGM = LibStub("AceAddon-3.0"):GetAddon("GatherMate2", true)
	if not tGM or not tGM.db or not tGM.db.profile then
		Announce(Sku.deEn and Sku.deEn("GatherMate2-Einstellungen nicht gefunden", "GatherMate2 settings not found", "Réglages GatherMate2 introuvables") or "Réglages GatherMate2 introuvables")
		Log("ToggleGatherMateMinimapIcons: GatherMate2 AceAddon object or db.profile missing.")
		return
	end

	tGM.db.profile.showMinimap = not tGM.db.profile.showMinimap
	local tNewState = tGM.db.profile.showMinimap

	local tOkMod, tDisplay = pcall(tGM.GetModule, tGM, "Display", true)
	if tOkMod and tDisplay and tDisplay.UpdateMaps then
		pcall(tDisplay.UpdateMaps, tDisplay)
	end

	if tNewState then
		Announce(Sku.deEn and Sku.deEn("GatherMate2-Minikartensymbole aktiviert", "GatherMate2 minimap icons enabled", "Icônes minicarte GatherMate2 activées") or "Icônes minicarte GatherMate2 activées")
	else
		Announce(Sku.deEn and Sku.deEn("GatherMate2-Minikartensymbole deaktiviert", "GatherMate2 minimap icons disabled", "Icônes minicarte GatherMate2 désactivées") or "Icônes minicarte GatherMate2 désactivées")
	end
	Log("ToggleGatherMateMinimapIcons: showMinimap now %s.", tostring(tNewState))
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-18, LOCALIZATION FIX] GatherMate2 mining/herb node-type ids ->
-- {deDE=,enUS=,frFR=} display name, one entry per client language instead of
-- a single hardcoded French string. THIS MATTERS FOR CORRECTNESS, not just
-- cosmetics: CheckNodePresence (below) compares this name against
-- SkuCore.MinimapScanner:MinimapScanChildFrames()'s blip table, and that
-- table is keyed by `tChildRessourceTypes[r][x][Sku.LocP]` (SkuCore/
-- minimapScanner.lua) -- i.e. the name in the CLIENT's OWN locale, not
-- always French. A hardcoded French name only ever matched by coincidence
-- on a frFR client; on an enUS or deDE client the presence check would NEVER
-- find a match and every single node would be wrongly reported "absent" and
-- skipped immediately, silently breaking the whole addon. Found and fixed
-- during the 2026-08-18 translation/compatibility pass, before any non-FR
-- client ever ran this code.
--
-- Values are taken from Sku's OWN already-3-language SkuCore.RessourceTypes
-- .mining / .herbs tables (SkuCore/minimapScanner.lua) -- NOT re-translated
-- here -- so the wording matches exactly what Sku itself already speaks for
-- the same ore/herb elsewhere. Sku indexes those tables by ITS OWN internal
-- number (1-27 mining, 1-45 herbs), completely different from GatherMate2's
-- ids (201-224, 401-442), so bridging them required matching each entry by
-- its English node name (both ultimately come from the same Blizzard game
-- data, so the English text is identical either side) -- done by hand,
-- cross-referencing GatherMate2/Constants.lua's node_ids literally against
-- SkuCore/minimapScanner.lua's SkuCore.RessourceTypes, both re-read fresh
-- from disk for this pass rather than trusted from memory.
--
-- Ids with NO match in Sku's table (218-220 Anniversary-only Lesser
-- Bloodstone/Incendicite/Indurium ores, 441-442 Flame Cap/Netherdust Bush --
-- none of which Sku's own scanner recognizes by name in any language) keep
-- a single raw GatherMate2 English string for all three languages -- exactly
-- as before, just now explicit about it being the same in each language
-- rather than a silent French-only gap.
local function tRT(aEn, aDe, aFr) return { enUS = aEn, deDE = aDe, frFR = aFr } end
local MINING_NAMES = {
	[201] = tRT("Copper Vein", "Kupfervorkommen", "Filon de cuivre"),
	[202] = tRT("Tin Vein", "Zinnvorkommen", "Filon d'étain"),
	[203] = tRT("Iron Deposit", "Eisenvorkommen", "Gisement de fer"),
	[204] = tRT("Silver Vein", "Silbervorkommen", "Filon d'argent"),
	[205] = tRT("Gold Vein", "Goldvorkommen", "Filon d'or"),
	[206] = tRT("Mithril Deposit", "Mithrilablagerung", "Gisement de mithril"),
	[207] = tRT("Ooze Covered Mithril Deposit", "Brühschlammbedeckte Mithrilablagerung", "Gisement de mithril couvert de vase"),
	[208] = tRT("Truesilver Deposit", "Echtsilberablagerung", "Gisement de vrai-argent"),
	[209] = tRT("Ooze Covered Silver Vein", "Brühschlammbedecktes Silbervorkommen", "Filon d'argent couvert de limon"),
	[210] = tRT("Ooze Covered Gold Vein", "Brühschlammbedecktes Goldvorkommen", "Filon d'or couvert de limon"),
	[211] = tRT("Ooze Covered Truesilver Deposit", "Brühschlammbedeckte Echtsilberablagerung", "Gisement de vrai-argent couvert de vase"),
	[212] = tRT("Ooze Covered Rich Thorium Vein", "Brühschlammbedecktes reiches Thoriumvorkommen", "Riche filon de thorium couvert de limon"),
	[213] = tRT("Ooze Covered Thorium Vein", "Brühschlammbedecktes Thoriumvorkommen", "Filon de thorium couvert de limon"),
	[214] = tRT("Small Thorium Vein", "Kleines Thoriumvorkommen", "Petit filon de thorium"),
	[215] = tRT("Rich Thorium Vein", "Reiches Thoriumvorkommen", "Riche filon de thorium"),
	[217] = tRT("Dark Iron Deposit", "Dunkeleisenablagerung", "Gisement de sombrefer"),
	[218] = tRT("Lesser Bloodstone Deposit", "Lesser Bloodstone Deposit", "Lesser Bloodstone Deposit"),
	[219] = tRT("Incendicite Mineral Vein", "Incendicite Mineral Vein", "Incendicite Mineral Vein"),
	[220] = tRT("Indurium Mineral Vein", "Indurium Mineral Vein", "Indurium Mineral Vein"),
	[221] = tRT("Fel Iron Deposit", "Teufelseisenvorkommen", "Gisement de gangrefer"),
	[222] = tRT("Adamantite Deposit", "Adamantitablagerung", "Gisement d'adamantite"),
	[223] = tRT("Rich Adamantite Deposit", "Reiche Adamantitablagerung", "Riche gisement d'adamantite"),
	[224] = tRT("Khorium Vein", "Khoriumvorkommen", "Filon de khorium"),
}

-- [2026-08-18, secondary priority] Same treatment for herbs, GatherMate2 ids
-- 401-442 (GatherMate2/Constants.lua node_ids["Herb Gathering"]) -- verified
-- against GatherMate2/Constants.lua's own node_expansion table: 401-431 are
-- Classic-era, 432-442 are BC -- 443+ is Wrath-only and cannot spawn on this
-- client (same cutoff reasoning as MINING_NAMES above). Ids 406/419/430
-- (Swiftthistle/Wildvine/Bloodvine) are commented out in GatherMate2's own
-- table -- they're picked up as part of another herb's node, never their
-- own -- so there is nothing to map for them.
local HERB_NAMES = {
	[401] = tRT("Peacebloom", "Friedensblume", "Pacifique"),
	[402] = tRT("Silverleaf", "Silberblatt", "Feuillargent"),
	[403] = tRT("Earthroot", "Erdwurzel", "Terrestrine"),
	[404] = tRT("Mageroyal", "Maguskönigskraut", "Mage royal"),
	[405] = tRT("Briarthorn", "Wilddornrose", "Eglantine"),
	[407] = tRT("Stranglekelp", "Würgetang", "Etouffante"),
	[408] = tRT("Bruiseweed", "Beulengras", "Doulourante"),
	[409] = tRT("Wild Steelbloom", "Wildstahlblume", "Aciérite sauvage"),
	[410] = tRT("Grave Moss", "Grabmoos", "Tombeline"),
	[411] = tRT("Kingsblood", "Königsblut", "Sang-royal"),
	[412] = tRT("Liferoot", "Lebenswurz", "Viétérule"),
	[413] = tRT("Fadeleaf", "Blassblatt", "Pâlerette"),
	[414] = tRT("Goldthorn", "Golddorn", "Dorépine"),
	[415] = tRT("Khadgar's Whisker", "Khadgars Schnurrbart", "Moustache de Khadgar"),
	[416] = tRT("Wintersbite", "Winterbiss", "Hivernale"),
	[417] = tRT("Firebloom", "Feuerblüte", "Fleur de feu"),
	[418] = tRT("Purple Lotus", "Lila Lotus", "Lotus pourpre"),
	[420] = tRT("Arthas' Tears", "Arthas' Tränen", "Larme d'Arthas"),
	[421] = tRT("Sungrass", "Sonnengras", "Soleillette"),
	[422] = tRT("Blindweed", "Blindkraut", "Aveuglette"),
	[423] = tRT("Ghost Mushroom", "Geisterpilz", "Champignon fantôme"),
	[424] = tRT("Gromsblood", "Gromsblut", "Sang de Grom"),
	[425] = tRT("Golden Sansam", "Goldener Sansam", "Sansam doré"),
	[426] = tRT("Dreamfoil", "Traumblatt", "Feuille de rêve"),
	[427] = tRT("Mountain Silversage", "Bergsilbersalbei", "Sauge-argent de montagne"),
	[428] = tRT("Plaguebloom", "Pestblüte", "Peste fleurie"),
	[429] = tRT("Icecap", "Eiskappe", "Cap glacé"),
	[431] = tRT("Black Lotus", "Schwarzer Lotus", "Lotus noir"),
	[432] = tRT("Felweed", "Teufelsgras", "Gangreherbe"),
	[433] = tRT("Dreaming Glory", "Traumwinde", "Gloire des rêves"),
	[434] = tRT("Terocone", "Terozapfen", "Cône de terre"),
	[435] = tRT("Ancient Lichen", "Urflechte", "Lichen ancien"),
	[436] = tRT("Bloodthistle", "Blutdistel", "Chardon sanglant"),
	[437] = tRT("Mana Thistle", "Manadistel", "Chardon de mana"),
	[438] = tRT("Netherbloom", "Netherblüte", "Pétale-de-néant"),
	[439] = tRT("Nightmare Vine", "Alptraumranke", "Vigne cauchemar"),
	[440] = tRT("Ragveil", "Zottelkappe", "Voile-de-raz"),
	[441] = tRT("Flame Cap", "Flame Cap", "Flame Cap"),
	[442] = tRT("Netherdust Bush", "Netherdust Bush", "Netherdust Bush"),
}

-- [2026-08-18] Resource "category" descriptor -- lets the exact same route
-- engine below (StartCloseRouteTo, AdvanceToTarget, FinishCurrentTarget,
-- CheckNodePresence, WatchRouteProgress, StartRoute, ...) serve more than
-- one GatherMate2 database without duplicating any of that logic. Mining
-- was the first, fully-tested category; Herb Gathering reuses every one of
-- those functions completely unchanged -- only the category descriptor
-- passed in differs.
local RESOURCE_CATEGORIES = {
	Mining = {
		dbGlobal = "GatherMate2MineDB",
		importArg = "Mines",
		baseName = "Route de minage",
		names = MINING_NAMES,
		fallbackPrefix = "Minerai",
	},
	Herb = {
		dbGlobal = "GatherMate2HerbDB",
		importArg = "Herbs",
		baseName = "Route d'herbes",
		names = HERB_NAMES,
		fallbackPrefix = "Herbe",
	},
}

-- [2026-08-18, LOCALIZATION FIX] Resolves to the CLIENT's own language
-- (Sku.LocP -- "deDE"/"enUS"/"frFR", set from GetLocale() by Sku itself,
-- Sku/Core.lua) instead of always French. Falls back to enUS then deDE if
-- Sku.LocP is unavailable or the specific entry has no frFR/whatever-locale
-- variant -- same safety-net order Sku's own minimapScanner.lua uses for its
-- identical FR-extension table. This is what CheckNodePresence's minimap
-- match, the "Choisir un type" submenu labels, and every spoken node name
-- are built from -- see MINING_NAMES/HERB_NAMES's own comment above for why
-- matching Sku's own displayed language here is a correctness requirement,
-- not a cosmetic choice.
local function ResourceTypeName(aCategory, aTypeId)
	local tEntry = aCategory.names[aTypeId]
	if not tEntry then return aCategory.fallbackPrefix .. " #" .. tostring(aTypeId) end
	local tLoc = (Sku and Sku.LocP) or "enUS"
	return tEntry[tLoc] or tEntry.enUS or tEntry.deDE
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Exact inverse of GatherMate2's own GatherMate:EncodeLoc (GatherMate2/
-- GatherMate2.lua) -- see the file header comment for why this is
-- replicated rather than called into GatherMate2 (it's pure arithmetic on
-- data already read from GatherMate2's own SavedVariable).
local mfloor = math.floor
local function DecodeGatherMateCoord(aId)
	return mfloor(aId / 1000000) / 10000, mfloor(aId % 1000000 / 100) / 10000
end

---------------------------------------------------------------------------------------------------------------------------------------
-- (uiMapId, xFrac, yFrac) -> Sku waypoint fields, or nil if the conversion
-- fails (unmapped uiMapId, or C_Map has nothing for this position -- e.g. an
-- indoor/instance uiMapId with no world terrain). Mirrors SkuNav:
-- ProcessPlayerDead's own C_Map.GetWorldPosFromMapPos + GetAreaData usage
-- (SkuNav/Core.lua) -- see the file header comment for the full reasoning.
local function NodeToWaypointData(aUiMapId, aX, aY)
	local tAreaId = SkuNav:GetAreaIdFromUiMapId(aUiMapId)
	if not tAreaId then return nil end

	local tOk, tInstanceId, tWorldPos = pcall(C_Map.GetWorldPosFromMapPos, aUiMapId, CreateVector2D(aX, aY))
	if not tOk or not tWorldPos then return nil end
	local tWorldX, tWorldY = tWorldPos:GetXY()
	if not tWorldX or not tWorldY then return nil end

	local tContinentId = select(3, SkuNav:GetAreaData(tAreaId)) or -1

	return {
		contintentId = tContinentId,
		areaId = tAreaId,
		worldX = tWorldX,
		worldY = tWorldY,
	}
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Every uiMapId worth checking for the player's CURRENT position: Sku's own
-- GetBestMapForUnit (which has extra edge-case overrides layered on top of
-- Blizzard's, see SkuNav/Geo.lua) first, then the raw C_Map.GetBestMapForUnit
-- as a fallback in case GatherMate2 stored a node under the id Sku's
-- overrides steer away from for a given subzone. Cheap to check both;
-- avoids a real "0 nodes found" false negative in an edge-case zone at the
-- cost of a couple of extra table lookups.
local function GetCandidateUiMapIds()
	local tIds, tSeen = {}, {}
	local tSkuMap = SkuNav:GetBestMapForUnit("player")
	local tRawMap = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	for _, id in ipairs({ tSkuMap, tRawMap }) do
		if id and not tSeen[id] then
			tSeen[id] = true
			tIds[#tIds + 1] = id
		end
	end
	return tIds
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-19, feature] "Garder en mémoire pendant environ 1h le cheminement
-- déjà suivi, les spots déjà passés, ainsi que ceux où il n'y avait rien,
-- pour optimiser la route ou la reprise" -- requested directly. Every node
-- this addon ever finishes with (reached, manually skipped, or found absent
-- -- any FinishCurrentTarget reason, deliberately unified rather than
-- special-cased: all three mean "already dealt with, don't re-offer") is
-- recorded here, keyed by its STABLE GatherMate2 identity -- category +
-- uiMapId + the raw coordinate key GatherMate2's own database already uses
-- (tCoordId in ScanZoneNodes below -- a perfect, already-unique per-position
-- id, no new derivation needed). ScanZoneNodes skips any node whose entry
-- here is still fresh when building a route, so stopping and restarting
-- naturally resumes with only what's left instead of re-walking everything.
--
-- Persisted as its own SavedVariable (SkuGatherRouteRecentDB, declared in
-- the .toc) rather than session-only state, since "stopped and restarted
-- LATER" in the request includes a full relog, not just a same-session
-- route restart. Timestamps use time() (Unix epoch, stable across a relog)
-- rather than GetTime() (resets on client restart, would make every entry
-- look instantly stale after exactly the kind of restart this needs to
-- survive).
local RECENT_MEMORY_TTL = 3600 -- ~1h, per the request

local function tRecentNodeKey(aCategory, aUiMapId, aCoordId)
	return aCategory.dbGlobal .. ":" .. aUiMapId .. ":" .. aCoordId
end

-- Records aReason (whatever FinishCurrentTarget was called with) for one
-- node. Safe to call liberally -- a later call for the same node just
-- refreshes its timestamp.
local function RecordRecentNode(aCategory, aUiMapId, aCoordId, aReason)
	if type(SkuGatherRouteRecentDB) ~= "table" then SkuGatherRouteRecentDB = {} end
	SkuGatherRouteRecentDB[tRecentNodeKey(aCategory, aUiMapId, aCoordId)] = { t = time(), reason = aReason }
end

local function IsNodeRecent(aCategory, aUiMapId, aCoordId)
	if type(SkuGatherRouteRecentDB) ~= "table" then return false end
	local tEntry = SkuGatherRouteRecentDB[tRecentNodeKey(aCategory, aUiMapId, aCoordId)]
	if not tEntry or type(tEntry) ~= "table" or not tEntry.t then return false end
	return (time() - tEntry.t) < RECENT_MEMORY_TTL
end

-- Sweeps genuinely expired entries out of the persisted table so it doesn't
-- grow unbounded over long play sessions / many sessions. IsNodeRecent above
-- already treats an expired-but-not-yet-swept entry as "not recent" on its
-- own, so this is pure housekeeping, not a correctness dependency -- called
-- once at OnEnable and again at the start of every ScanZoneNodes (i.e. every
-- route start), which is plenty frequent for that purpose without needing a
-- dedicated background timer.
local function PruneRecentNodeMemory()
	if type(SkuGatherRouteRecentDB) ~= "table" then return end
	local tNow = time()
	local tRemoved = 0
	for tKey, tEntry in pairs(SkuGatherRouteRecentDB) do
		if type(tEntry) ~= "table" or not tEntry.t or (tNow - tEntry.t) >= RECENT_MEMORY_TTL then
			SkuGatherRouteRecentDB[tKey] = nil
			tRemoved = tRemoved + 1
		end
	end
	if tRemoved > 0 then Log("PruneRecentNodeMemory: removed %d expired entrie(s).", tRemoved) end
end

-- Menu-reachable manual reset (Shift+F1 -> Route de minage/d'herbes ->
-- "Vider la mémoire des nœuds récents") -- clears BOTH categories at once
-- (the memory isn't split by which menu you happen to be in), for anyone who
-- wants a full fresh scan without waiting out the hour.
local function ClearRecentNodeMemory()
	local tCount = 0
	if type(SkuGatherRouteRecentDB) == "table" then
		for _ in pairs(SkuGatherRouteRecentDB) do tCount = tCount + 1 end
	end
	SkuGatherRouteRecentDB = {}
	Announce((Sku.deEn and Sku.deEn("Erinnerung geloescht: ", "Memory cleared: ", "Mémoire effacée : ") or "Mémoire effacée : ")
		.. tCount .. " " .. (Sku.deEn and Sku.deEn("Eintraege", "entries", "entrées") or "entrées"))
	Log("ClearRecentNodeMemory: cleared %d entrie(s).", tCount)
end

local MAX_ROUTE_NODES = 300 -- soft safety cap, well above any single zone/ore-type's real node count

-- Scans aCategory's GatherMate2 database (GatherMate2MineDB / HerbDB) for
-- the player's current zone. aTypeFilter is nil (every type in the
-- category) or a set {[gatherMateTypeId]=true, ...} to restrict to. Skips
-- any node still within RECENT_MEMORY_TTL of a previous finish (see
-- RecordRecentNode/IsNodeRecent above). Returns a list of {worldX, worldY,
-- contintentId, areaId, typeId, uiMapId, coordId}.
local function ScanZoneNodes(aCategory, aTypeFilter)
	PruneRecentNodeMemory()
	local tResults = {}
	local tDB = _G[aCategory.dbGlobal]
	if type(tDB) ~= "table" then
		Log("ScanZoneNodes: %s missing or not a table.", aCategory.dbGlobal)
		return tResults
	end

	local tSkippedRecent = 0
	for _, tUiMapId in ipairs(GetCandidateUiMapIds()) do
		local tZoneDb = tDB[tUiMapId]
		if type(tZoneDb) == "table" then
			for tCoordId, tTypeId in pairs(tZoneDb) do
				if (not aTypeFilter or aTypeFilter[tTypeId]) and #tResults < MAX_ROUTE_NODES then
					if IsNodeRecent(aCategory, tUiMapId, tCoordId) then
						tSkippedRecent = tSkippedRecent + 1
					else
						local tX, tY = DecodeGatherMateCoord(tCoordId)
						local tWpData = NodeToWaypointData(tUiMapId, tX, tY)
						if tWpData then
							tWpData.typeId = tTypeId
							tWpData.uiMapId = tUiMapId
							tWpData.coordId = tCoordId
							tResults[#tResults + 1] = tWpData
						end
					end
				end
			end
		end
	end

	Log("ScanZoneNodes: db=%s filter=%s found=%d skippedRecent=%d", aCategory.dbGlobal, aTypeFilter and "set" or "all", #tResults, tSkippedRecent)
	return tResults
end

-- Every distinct node type of aCategory actually present around the player
-- right now, sorted by name -- used to build the "choose one" submenu so it
-- only ever lists types that can actually be found here, not the whole
-- category every time.
local function GetPresentTypesInZone(aCategory)
	local tSeen = {}
	local tDB = _G[aCategory.dbGlobal]
	if type(tDB) == "table" then
		for _, tUiMapId in ipairs(GetCandidateUiMapIds()) do
			local tZoneDb = tDB[tUiMapId]
			if type(tZoneDb) == "table" then
				for _, tTypeId in pairs(tZoneDb) do
					tSeen[tTypeId] = true
				end
			end
		end
	end
	local tList = {}
	for tTypeId in pairs(tSeen) do
		tList[#tList + 1] = { typeId = tTypeId, name = ResourceTypeName(aCategory, tTypeId) }
	end
	table.sort(tList, function(a, b) return a.name < b.name end)
	return tList
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Active-route state. tActiveRouteNames tracks the waypoint names THIS
-- addon created for the current run, in no particular order. tCurrentTarget
-- is the ONE node currently being navigated to (real close route or
-- fallback direct waypoint -- see StartCloseRouteTo below). tActiveCategory
-- is the RESOURCE_CATEGORIES entry (Mining or Herb) the current/last route
-- was started with -- a route is always one category at a time, never
-- mixed, so this single shared variable (rather than per-node) is enough;
-- set at the top of StartRoute, read anywhere the waypoint base name is
-- needed (waypoint naming, GetClosestWaypointFromBaseName).
local tActiveCategory = RESOURCE_CATEGORIES.Mining
local tActiveRouteNames = {}
local tActiveRouteNameSet = {}
local tActiveRouteNodeName = {} -- [wpName] = expected French ore name, for the presence check below
local tActiveRouteNodeIdentity = {} -- [wpName] = {uiMapId=, coordId=} -- the GatherMate2 identity, for RecordRecentNode on finish
local tPresenceChecked = {} -- [wpName] = true once the presence check has CONCLUDED for it (found, or given up after enough misses)
local tPresenceMissStreak = 0 -- consecutive "not found" scans for the CURRENT target, reset on every advance -- see CheckNodePresence
local tRouteTicker
local tCurrentTarget

-- [2026-08-17] "Check at ~50m that the ore is actually still there, skip
-- ahead if not, so time isn't wasted flying/walking to an empty spot" --
-- requested directly. GatherMate2's data can be stale (mined out since it
-- was recorded, or by someone else moments ago); this catches that BEFORE
-- committing to the full approach, not just after physically arriving.
-- Uses Sku's OWN minimap-blip detection (SkuCore.MinimapScanner
-- :MinimapScanChildFrames, SkuCore/minimapScanner.lua -- the exact routine
-- Sku's own passive resource-scanner uses) rather than reimplementing
-- minimap reading.
--
-- [2026-08-18, revised after a real false-negative was reported] Used to
-- read the minimap AS-IS with no zoom change, on the reasoning that a
-- zoomed-in minimap's small accuracy loss was an acceptable trade for
-- simplicity. That accuracy loss turned out to actually bite: a node well
-- within tPresenceCheckRange by ground distance can still be OUTSIDE a
-- tightly zoomed-in minimap's visible radius, so it never renders as a
-- minimap child frame and the scan honestly (but wrongly) finds nothing.
-- CheckNodePresence now zooms the minimap fully out for the scan and
-- restores the player's own zoom immediately after (synchronous, same
-- tick), plus requires several consecutive misses before concluding
-- absence rather than trusting a single scan -- see that function's own
-- comment for the full reasoning.
-- Biased toward NOT skipping when unsure (missing MinimapScanner, a failed
-- scan, or simply not being within range yet all leave the node alone) --
-- a false "still there" costs nothing beyond today's behaviour (manual
-- Ctrl+Shift+W skip is always available); a false "it's gone" would rob the
-- player of a node that was actually there, which is the worse mistake.
-- Requires GatherMate2's own minimap icons to be OFF (see
-- ToggleGatherMateMinimapIcons above) -- otherwise its persistent icon at
-- this exact spot is what gets matched, not a live Blizzard blip, and the
-- check always reports "present" (found by the user testing this).
--
-- [2026-08-18] A mutable local (not a true constant) -- adjustable at
-- runtime via the "Portée de vérification" menu picker (see
-- SetPresenceCheckRange below), so the 50y default can be tuned per
-- session without editing code. Resets to 50 on the next /reload -- kept
-- session-scoped rather than a persisted SavedVariable on purpose, to avoid
-- adding a settings schema for one number; simple enough to re-pick each
-- session from the menu if a different value is wanted again.
local tPresenceCheckRange = 50 -- yards
-- Matches this addon's own waypoint size=1 (SkuNav/data.lua SkuNavWpSize[1]
-- = 1 yard) -- the same "arrived" precision every other size=1 Sku waypoint
-- uses (e.g. minimapScanner.lua's Quick Waypoints).
local ARRIVAL_RANGE = 1 -- yards

-- [2026-08-18] "Guide point par point... pas me retrouver bloqué dans une
-- montagne" -- how far from the actual ore node StartCloseRouteTo will
-- accept a graph-linked waypoint as the route's landing point. Sku's own
-- close-route algorithm (and this addon's copy of it) only ever PATHFINDS
-- between waypoints that are already part of its known network -- the very
-- last stretch, from that landing point to the real target, is always a
-- straight beacon line with no terrain awareness at all (true of Sku's
-- distance/direction math everywhere: SkuNav:Distance is a flat 2D
-- calculation, it has no notion of elevation, so it cannot tell "walk
-- straight there" from "that's a cliff face"). A SHORTER straight-line tail
-- is a shorter stretch where that blind spot can strand the player, so this
-- was tightened from Sku's own menu default of 500 yards down to 150. The
-- trade-off: a genuinely remote node (nothing graph-linked within 150y) now
-- falls back to a plain waypoint MORE readily -- which is the honest
-- outcome anyway, since a "close route" whose last 400+ yards were just as
-- blind as a full fallback would have been was never really safer, just
-- nominally labelled "precise".
local MAX_TARGET_APPROACH_DISTANCE = 150 -- yards

-- [2026-08-18] "Pas me retrouver bloqué dans une montagne" -- a second,
-- complementary mitigation. Sku's distance/direction math (SkuNav:Distance,
-- used everywhere including this addon) is flat 2D -- it has no concept of
-- elevation at all, and neither GatherMate2 nor C_Map.GetWorldPosFromMapPos
-- expose a node's height, so there is no data available anywhere in this
-- pipeline to compute "climb" or "descend" guidance from (checked before
-- writing this comment, not assumed). What CAN be detected without height
-- data: the player is actively moving but not actually getting any closer
-- to the target -- exactly the signature of being stuck against a cliff
-- face or wall while still holding a direction key / flying forward. When
-- that happens for STUCK_CHECK_INTERVAL seconds in a row, this announces it
-- once, so the player knows to stop, look around, or use "Sauter ce
-- minerai" instead of continuing to push into whatever is blocking them.
--
-- [2026-08-19, FALSE-POSITIVE FIX] Originally measured "progress" as the
-- straight-line distance to the FINAL target getting shorter. That's wrong
-- for a real close route: the path to a graph-linked entry point is rarely
-- a straight line to the ultimate target -- it can legitimately curve away
-- from it for a while (around a mountain, through a pass, along a road) while
-- the player is making completely normal progress ALONG THE PATH. Straight-
-- line distance to a point kilometers past the next few hops can easily
-- stay flat or even increase during a perfectly healthy leg, which is
-- exactly the false "bloqué" the user reported happening "sans raison".
-- Fixed: measure the player's own WORLD POSITION change instead (raw
-- displacement, direction-agnostic) -- this only reads "am I actually
-- moving through space at all", completely independent of the path's shape
-- or how it relates to the final target. A player genuinely wedged against
-- terrain barely moves at all regardless of which way the path curves;
-- a player making normal progress along ANY path (straight or curved)
-- reliably displaces several yards over STUCK_CHECK_INTERVAL.
local STUCK_CHECK_INTERVAL = 15 -- seconds
local STUCK_MIN_PROGRESS = 10 -- yards -- must physically move at least this much per interval to count as "making progress"
local tStuckLastWorldX, tStuckLastWorldY
local tStuckLastCheckTime
local tStuckAnnounced

-- [2026-08-18] Menu-driven customisation for tPresenceCheckRange -- see
-- that variable's own comment for why this is session-scoped rather than a
-- persisted setting.
local function SetPresenceCheckRange(aRange)
	tPresenceCheckRange = aRange
	Announce((Sku.deEn and Sku.deEn("Erkennungsreichweite", "Detection range", "Portée de détection") or "Portée de détection")
		.. " " .. aRange .. " " .. (Sku.deEn and Sku.deEn("Meter", "yards", "mètres") or "mètres"))
	Log("SetPresenceCheckRange: now %d yards.", aRange)
end

-- Removes every currently-tracked route waypoint from SkuNav and resets
-- state. Safe to call with no active route (no-op). Does NOT touch
-- SkuNav.isAutoSelectEnabled or call EndFollowingWpOrRt by itself -- callers
-- (StopRoute / a fresh StartRoute clearing the previous run) decide that
-- separately, so this stays a pure "remove what I own" primitive.
local function ClearRouteWaypoints()
	for _, tName in ipairs(tActiveRouteNames) do
		pcall(SkuNav.DeleteWaypoint, SkuNav, tName, true)
	end
	Log("ClearRouteWaypoints: removed %d waypoint(s).", #tActiveRouteNames)
	tActiveRouteNames = {}
	tActiveRouteNameSet = {}
	tActiveRouteNodeName = {}
	tActiveRouteNodeIdentity = {}
	tPresenceChecked = {}
	tPresenceMissStreak = 0
	tCurrentTarget = nil
	tStuckLastWorldX, tStuckLastWorldY = nil, nil
	tStuckLastCheckTime = nil
	tStuckAnnounced = false
end

local function StopRouteTicker()
	if tRouteTicker then
		tRouteTicker:Cancel()
		tRouteTicker = nil
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-17] Real "close route" (metaroute) navigation to a single target,
-- requested directly ("pas à pas et non pas en mode waypoint") -- driven
-- entirely by Sku's own pathfinding primitives. Reproduces exactly what
-- SkuNav.WaypointSelectOnAction's close-route branch and
-- SkuNav_MenuBuilder_WaypointSelectionMenu's "Nahe Routen" computation do
-- (both in Sku/SkuNav/Options.lua), just without the menu-hover UI wrapper
-- around them, since the target here is picked programmatically instead of
-- by the player browsing a list. Every field written in the "Commit" section
-- below and the order it's written in mirrors that original code as closely
-- as possible -- this is Sku's OWN proven algorithm, not a new one, to keep
-- the risk of a silent navigation bug as low as possible for something a
-- blind player is physically following in real time.
--
-- Search phase: find, among up to 10 graph-linked waypoints near the player
-- (SkuNav:GetAllLinkedWPsInRangeToCoords), the one whose path (SkuNav:
-- GetAllMetaTargetsFromWp5) reaches closest to a graph-linked waypoint near
-- the actual target (SkuNav:GetNearestWpsWithLinksToWp) -- "closest" scored
-- by the same weighted distance Sku's own menu uses
-- (SkuNav.BestRouteWeightedLengthModForMetaDistance).
--
-- Falls back to a plain SkuNav:SelectWP (still fully functional, just a
-- straight-line beacon instead of a real path) whenever no viable graph
-- path is found -- e.g. standing somewhere Sku's own route data has no
-- coverage yet, or the target itself is too far from the known network.
-- Returns true if a real close route was started, false if it fell back.
local function StartCloseRouteTo(aTargetWpName)
	local function FallBack(aWhy)
		Log("StartCloseRouteTo: %s -- falling back to direct waypoint for '%s'.", aWhy, aTargetWpName)
		if SkuSettings:Sub("SkuNav").metapathFollowing == true or SkuSettings:Sub("SkuNav").selectedWaypoint ~= "" then
			SkuNav:EndFollowingWpOrRt()
		end
		-- Clean slate: clear any half-written metapathFollowing* fields from
		-- an aborted commit attempt (e.g. the "full path recomputation
		-- failed" case below writes Start/Target/EndTarget before finding
		-- out) so nothing stale is left for later code to misread.
		SkuSettings:Sub("SkuNav").metapathFollowing = false
		SkuSettings:Sub("SkuNav").metapathFollowingStart = nil
		SkuSettings:Sub("SkuNav").metapathFollowingTarget = nil
		SkuSettings:Sub("SkuNav").metapathFollowingEndTarget = nil
		SkuSettings:Sub("SkuNav").metapathFollowingMetapaths = nil
		SkuSettings:Sub("SkuNav").metapathFollowingCurrentWp = nil
		-- Silent (aNoVoice=true) to match the close-route success path below
		-- (which also selects its first hop silently) -- a route can have
		-- hundreds of nodes, many of which may fall back if the player is
		-- off the known path network; a "waypoint selected" TTS callout on
		-- every single one of those would be exhausting. The beacon sound
		-- SelectWP creates is unconditional either way, so guidance is never
		-- actually silent, just the extra spoken confirmation.
		SkuNav:SelectWP(aTargetWpName, true)
		SkuNav.lastSelectedWaypointFullName = aTargetWpName
		return false
	end

	local tPlayX, tPlayY = UnitPosition("player")
	if not tPlayX then return FallBack("no player position") end

	local tOk1, tEntryCandidates = pcall(SkuNav.GetAllLinkedWPsInRangeToCoords, SkuNav, tPlayX, tPlayY, SkuNav.MaxMetaEntryRange)
	if not tOk1 or type(tEntryCandidates) ~= "table" or not next(tEntryCandidates) then
		return FallBack("no graph entry point near the player")
	end

	local tSortedEntries = {}
	for _, v in pairs(tEntryCandidates) do tSortedEntries[#tSortedEntries + 1] = v end
	table.sort(tSortedEntries, function(a, b) return a.nearestWpRange < b.nearestWpRange end)

	local tTargetData = SkuNav:GetWaypointData2(aTargetWpName)
	if not tTargetData then return FallBack("target waypoint data missing") end

	-- [2026-08-18, perf] Computed ONCE here instead of inside the loop below
	-- -- it only depends on aTargetWpName, never on which entry candidate is
	-- being scored, so it was being recomputed identically up to 10 times
	-- per call for no reason. On a route with hundreds of nodes (this
	-- addon's normal case) that redundant work adds up to a real,
	-- measurable hitch on every single advance.
	local tOk3, tNearWps = pcall(SkuNav.GetNearestWpsWithLinksToWp, SkuNav, aTargetWpName, 10, MAX_TARGET_APPROACH_DISTANCE)
	if not tOk3 or type(tNearWps) ~= "table" or #tNearWps == 0 then
		return FallBack("no graph-linked waypoint near the target")
	end

	local tRoutesMaxDistance = SkuSettings:Sub("SkuNav").routesMaxDistance

	-- Search phase: best (entryStart, metarouteIndex) pair across up to 5
	-- nearby entry points (was 10 -- halved for the same perf reason as
	-- above: each candidate costs one full GetAllMetaTargetsFromWp5 graph
	-- traversal; the closest few entry points capture almost all of the
	-- benefit, and this is Sku's own menu-search algorithm just picking the
	-- global best directly instead of listing candidates for a player to
	-- browse, so a smaller candidate pool is a pure speed/quality trade,
	-- not a correctness change).
	local tBest
	for i = 1, math.min(#tSortedEntries, 5) do
		local tEntryName = tSortedEntries[i].nearestWP
		local tOk2, tMetapaths = pcall(SkuNav.GetAllMetaTargetsFromWp5, SkuNav, tEntryName, tRoutesMaxDistance, SkuNav.MaxMetaWPs, nil, true)
		if tOk2 and type(tMetapaths) == "table" then
			for x = 1, #tNearWps do
				local tCandidate = tMetapaths[tNearWps[x].wpName]
				if tCandidate then
					local tEndObj = SkuNav:GetWaypointData2(tNearWps[x].wpName)
					if tEndObj then
						local tDistToTarget = SkuNav:Distance(tEndObj.worldX, tEndObj.worldY, tTargetData.worldX, tTargetData.worldY) or 0
						local tWeighted = (tCandidate.distance / SkuNav.BestRouteWeightedLengthModForMetaDistance) + tDistToTarget
						if not tBest or tWeighted < tBest.weightedDistance then
							tBest = { entryStart = tEntryName, metarouteIndex = tNearWps[x].wpName, weightedDistance = tWeighted }
						end
					end
				end
			end
		end
	end

	if not tBest then
		return FallBack("no graph path reaches near the target")
	end

	-- Commit phase -- mirrors SkuNav.WaypointSelectOnAction's close-route
	-- branch (SkuNav/Options.lua) field-for-field.
	if SkuSettings:Sub("SkuNav").metapathFollowing == true or SkuSettings:Sub("SkuNav").selectedWaypoint ~= "" then
		SkuNav:EndFollowingWpOrRt()
	end
	SkuSettings:Sub("SkuNav").metapathFollowing = false
	SkuSettings:Sub("SkuNav").metapathFollowingStart = tBest.entryStart
	SkuSettings:Sub("SkuNav").metapathFollowingTarget = tBest.metarouteIndex
	SkuSettings:Sub("SkuNav").metapathFollowingEndTarget = aTargetWpName

	local tOk4, tFullMetapaths = pcall(SkuNav.GetAllMetaTargetsFromWp5, SkuNav,
		SkuSettings:Sub("SkuNav").metapathFollowingStart, tRoutesMaxDistance, SkuNav.MaxMetaWPs,
		SkuSettings:Sub("SkuNav").metapathFollowingTarget, true)
	if not tOk4 or type(tFullMetapaths) ~= "table" or not tFullMetapaths[SkuSettings:Sub("SkuNav").metapathFollowingTarget] then
		return FallBack("full path recomputation failed")
	end

	SkuSettings:Sub("SkuNav").metapathFollowingMetapaths = tFullMetapaths
	SkuSettings:Sub("SkuNav").metapathFollowingMetapaths[#SkuSettings:Sub("SkuNav").metapathFollowingMetapaths + 1] =
		SkuSettings:Sub("SkuNav").metapathFollowingEndTarget
	SkuSettings:Sub("SkuNav").metapathFollowingMetapaths[SkuSettings:Sub("SkuNav").metapathFollowingEndTarget] =
		SkuSettings:Sub("SkuNav").metapathFollowingMetapaths[SkuSettings:Sub("SkuNav").metapathFollowingTarget]
	table.insert(SkuSettings:Sub("SkuNav").metapathFollowingMetapaths[SkuSettings:Sub("SkuNav").metapathFollowingEndTarget].pathWps,
		SkuSettings:Sub("SkuNav").metapathFollowingEndTarget)
	SkuSettings:Sub("SkuNav").metapathFollowingTarget = SkuSettings:Sub("SkuNav").metapathFollowingEndTarget
	SkuSettings:Sub("SkuNav").metapathFollowingCurrentWp = 1
	SkuSettings:Sub("SkuNav").metapathFollowing = true
	SkuNav:SelectWP(SkuSettings:Sub("SkuNav").metapathFollowingStart, true)
	SkuNav.lastSelectedWaypointFullName = SkuSettings:Sub("SkuNav").metapathFollowingTarget

	Announce(Sku.deEn and Sku.deEn("Metaroute folgen gestartet", "Close route started", "Route précise démarrée") or "Route précise démarrée")
	Log("StartCloseRouteTo: started, entry='%s', target='%s'.", tBest.entryStart, aTargetWpName)
	return true
end

-- Makes aName the node currently being navigated to and (re)starts precise
-- navigation toward it. Used both for the very first target and for every
-- advance afterwards (arrival, manual skip, presence-check skip) -- always
-- through the same close-route path, never a plain one-shot SelectWP call
-- (per "à chaque lancement... pas à pas, non pas en mode waypoint").
local function AdvanceToTarget(aName)
	tCurrentTarget = aName
	tPresenceChecked[aName] = nil
	tPresenceMissStreak = 0
	-- Fresh baseline for the stuck check -- not strictly required any more
	-- (player world position, unlike the old target-distance metric, has no
	-- relationship to WHICH target is active), but resetting the check
	-- window here avoids a stray reading landing right at the seam of a
	-- target switch.
	tStuckLastWorldX, tStuckLastWorldY = nil, nil
	tStuckLastCheckTime = GetTime()
	tStuckAnnounced = false
	StartCloseRouteTo(aName)
end

-- Shared by arrival, manual skip and the presence check: aFinishedName is
-- done (reached or skipped, never revisited), remove it, and either advance
-- to the next-closest remaining node (same GetClosestWaypointFromBaseName
-- Sku's own auto-advance is built on) or declare the route complete.
local function FinishCurrentTarget(aReason)
	local tFinished = tCurrentTarget
	if not tFinished then return end

	local tNextName = SkuNav:GetClosestWaypointFromBaseName(tActiveCategory.baseName, tFinished)
	pcall(SkuNav.DeleteWaypoint, SkuNav, tFinished, true)

	-- [2026-08-19] Remember this node (any reason -- reached, skipped, or
	-- absent) for RECENT_MEMORY_TTL so a route restart doesn't re-offer it.
	-- See RecordRecentNode's own comment above.
	local tIdentity = tActiveRouteNodeIdentity[tFinished]
	if tIdentity then
		RecordRecentNode(tActiveCategory, tIdentity.uiMapId, tIdentity.coordId, aReason)
	end

	tActiveRouteNameSet[tFinished] = nil
	tActiveRouteNodeName[tFinished] = nil
	tActiveRouteNodeIdentity[tFinished] = nil
	tPresenceChecked[tFinished] = nil
	for i = #tActiveRouteNames, 1, -1 do
		if tActiveRouteNames[i] == tFinished then
			table.remove(tActiveRouteNames, i)
			break
		end
	end
	Log("FinishCurrentTarget: %s of '%s', %d remaining.", aReason, tFinished, #tActiveRouteNames)

	if tNextName and tActiveRouteNameSet[tNextName] then
		AdvanceToTarget(tNextName)
	else
		tCurrentTarget = nil
		StopRouteTicker()
		if SkuSettings:Sub("SkuNav").metapathFollowing == true or SkuSettings:Sub("SkuNav").selectedWaypoint ~= "" then
			SkuNav:EndFollowingWpOrRt()
		end
		Announce(Sku.deEn and Sku.deEn("Abbauroute beendet", "Gather route complete", "Route de minage terminée") or "Route de minage terminée")
		Log("FinishCurrentTarget: route complete, all nodes cleared.")
	end
end

-- [2026-08-18, FALSE-NEGATIVE FIX] Two real causes found for "there IS ore
-- right there but it skips to the next node anyway", reported directly by
-- the user after it happened on the final approach to a target:
--
-- 1. MinimapScanChildFrames() (SkuCore/minimapScanner.lua) only sees blips
--    that are CURRENTLY RENDERED on the minimap -- i.e. within the
--    minimap's own visible radius at whatever zoom level the player
--    currently has set. This addon's own header comment previously
--    documented reading the minimap "AS-IS (no zoom/state changes)" as a
--    deliberate simplicity/safety trade-off -- but that means a node at,
--    say, 45 yards ground distance (well inside the default 50y
--    tPresenceCheckRange) can be genuinely OUTSIDE a tightly zoomed-in
--    minimap's visible circle, so it never appears as a minimap child frame
--    at all and the scan honestly finds nothing, even though the resource
--    is really there. Fixed below: zoom the minimap fully OUT (level 0,
--    guaranteed to render every nearby blip) for the ~instant the scan
--    takes, then restore the player's own zoom immediately after --
--    synchronous, same tick, so there's no visible flicker. (Rotation is
--    left untouched -- it only affects blip POSITION, which this check
--    never reads, only presence-by-name.)
-- 2. Even a healthy scan can miss on any ONE given tick (tooltip content
--    still populating that exact frame, a transient minimap redraw, etc).
--    The check used to conclude "absent" from a SINGLE miss. Now it
--    requires PRESENCE_MISS_THRESHOLD consecutive misses (spread over the
--    0.15s ticker) before giving up -- a real find on any of those ticks
--    immediately confirms and stops checking; only a consistent run of
--    misses concludes true absence. The player is still closing distance
--    during that ~0.45s window regardless (arrival/stuck checks are
--    untouched), so this costs nothing when the node genuinely is gone.
local PRESENCE_MISS_THRESHOLD = 3

-- [2026-08-19, feature] "Le dernier point là où le minerai doit être est pas
-- très précis... vérifier s'il correspond bien à celui mentionné dans
-- shift+F9... et que le dernier point s'adapte" -- requested directly, and
-- confirmed by the user which feature they mean: Sku's own live minimap scan
-- (SKU_KEY_MMSCANWIDE, Ctrl+Shift+F by default) computes a node's position
-- from where its blip ACTUALLY sits on the minimap right now, which can
-- differ noticeably from GatherMate2's stored (uiMapId, x, y) -- a
-- community-recorded coordinate that can simply be off by a meaningful
-- margin, unrelated to any bug in this addon.
--
-- Reproduces the EXACT conversion Sku's own MinimapScanProcessResults
-- (SkuCore/minimapScanner.lua) uses to turn a minimap blip into a world
-- position -- not a re-derivation, a direct copy of that formula (same axis
-- inversion, same tMinimapYardsMod scale, same reasoning documented there:
-- "Achsen muessen invertiert werden" for the child-frame path). One
-- difference on purpose: Sku's own version adds a small +2.5/+0.5 offset
-- that comes from ITS OWN grid-scan cluster-merging padding (merging nearby
-- hits into one blob when sweeping the minimap blind) -- irrelevant here
-- since CheckNodePresence already has a single, precisely name-matched blip
-- from the fast child-frame path, so that offset is dropped as noise rather
-- than reproduced. tMinimapYardsMod is calibrated for a fully-zoomed-out
-- minimap (Minimap:GetZoom() == 0) -- which is exactly the state
-- CheckNodePresence's own zoom fix above already forces for the very same
-- scan call, so no extra zoom handling is needed here.
local tMinimapYardsMod = 3.125 -- yards per minimap pixel at zoom 0 -- copied from SkuCore/minimapScanner.lua
local REFINE_POSITION_THRESHOLD = 5 -- yards -- only correct the waypoint if the live scan disagrees with GatherMate2's stored position by at least this much (skips reacting to ordinary pixel-measurement noise)

local function RefineTargetPositionFromBlip(aWpName, aDx, aDy)
	local tPlayerX, tPlayerY = UnitPosition("player")
	if not tPlayerX then return end
	local tData = SkuNav:GetWaypointData2(aWpName)
	if not tData or not tData.worldX or not tData.worldY then return end

	-- Sku's own axis inversion (minimapScanner.lua's own comment: the
	-- child-frame path's dx/dy use natural screen convention -- dx>0 = east,
	-- dy>0 = north -- and must be negated before the world-position math
	-- below, which expects the OPPOSITE grid-scan convention).
	local tScreenX, tScreenY = -aDx, -aDy
	local tRefinedX = tPlayerX + (tScreenY * tMinimapYardsMod) * -1
	local tRefinedY = tPlayerY + (tScreenX * tMinimapYardsMod)

	local tOff = SkuNav:Distance(tData.worldX, tData.worldY, tRefinedX, tRefinedY)
	if not tOff or tOff < REFINE_POSITION_THRESHOLD then return end

	SkuNav:SetWaypoint(aWpName, {
		contintentId = tData.contintentId,
		areaId = tData.areaId,
		worldX = tRefinedX,
		worldY = tRefinedY,
		createdAt = GetTime(),
		createdBy = UnitName("player"),
		size = 1,
	}, true)
	Log("RefineTargetPositionFromBlip: '%s' adjusted by %.1fy toward the live minimap position (GatherMate2 data vs. Ctrl+Shift+F-style scan).", aWpName, tOff)
end

local function CheckNodePresence()
	if not tCurrentTarget or tPresenceChecked[tCurrentTarget] then return end
	local tDist = SkuNav:GetDistanceToWp(tCurrentTarget)
	if not tDist or tDist > tPresenceCheckRange then return end

	local tExpectedName = tActiveRouteNodeName[tCurrentTarget]
	if not tExpectedName then tPresenceChecked[tCurrentTarget] = true; return end
	if not SkuCore.MinimapScanner or not SkuCore.MinimapScanner.MinimapScanChildFrames then
		tPresenceChecked[tCurrentTarget] = true
		return
	end

	local tPrevZoom = Minimap:GetZoom()
	pcall(Minimap.SetZoom, Minimap, 0)
	local tOk, tBlips = pcall(SkuCore.MinimapScanner.MinimapScanChildFrames, SkuCore.MinimapScanner)
	pcall(Minimap.SetZoom, Minimap, tPrevZoom)

	if not tOk or type(tBlips) ~= "table" then
		Log("CheckNodePresence: scan failed for '%s' (ok=%s) -- leaving node alone, will retry.", tCurrentTarget, tostring(tOk))
		return -- doesn't count as a miss -- retry fresh next tick
	end

	if tBlips[tExpectedName] then
		tPresenceChecked[tCurrentTarget] = true
		Log("CheckNodePresence: '%s' confirmed present near '%s' (after %d miss(es)).", tExpectedName, tCurrentTarget, tPresenceMissStreak)
		local tOkRefine, tErrRefine = pcall(RefineTargetPositionFromBlip, tCurrentTarget, tBlips[tExpectedName].dx, tBlips[tExpectedName].dy)
		if not tOkRefine then Log("RefineTargetPositionFromBlip THREW: %s", tostring(tErrRefine)) end
		return
	end

	tPresenceMissStreak = tPresenceMissStreak + 1
	if tPresenceMissStreak < PRESENCE_MISS_THRESHOLD then
		Log("CheckNodePresence: '%s' not found near '%s' (miss %d/%d) -- retrying.", tExpectedName, tCurrentTarget, tPresenceMissStreak, PRESENCE_MISS_THRESHOLD)
		return
	end

	tPresenceChecked[tCurrentTarget] = true
	Announce(Sku.deEn and Sku.deEn("Nicht gefunden, weiter", "Not found, moving on", "Introuvable, suivant") or "Introuvable, suivant")
	FinishCurrentTarget("presence-check-absent")
end

-- [2026-08-18] Does NOT poll SkuNav.MoveToWp for a manual skip anymore --
-- confirmed by reading SkuNav/Core.lua's own OnUpdate driver
-- (the frame right after ProcessCheckReachingWp resets
-- SkuNav.MoveToWp = 0 unconditionally on roughly every 0.1s tick,
-- REGARDLESS of who consumed it) that this flag is racy for any OUTSIDE
-- code to poll: Sku's own faster ~0.1s cycle can clear it before this
-- addon's 0.15s ticker ever sees it, so relying on it here was never fully
-- reliable to begin with -- confirmed by the user's own testing. Manual
-- skip is instead the dedicated SkuGatherRoute:SkipCurrentTarget keybind
-- (Bindings.xml, default Ctrl+Shift+N) and the always-available "Sauter ce
-- minerai" menu entry, neither of which touch SkuNav.MoveToWp at all -- see
-- SkipCurrentTarget's own comment.
--
-- Arrival is checked directly via distance to tCurrentTarget
-- (SkuNav:GetDistanceToWp), independent of mode, rather than by watching
-- SkuSettings:Sub("SkuNav").selectedWaypoint -- that value cycles through
-- every intermediate path waypoint while a close route is under way, so it
-- cannot tell "reached one hop" from "reached the actual ore node".
local function WatchRouteProgress()
	if not tCurrentTarget then
		StopRouteTicker()
		return
	end

	CheckNodePresence()
	if not tCurrentTarget then return end -- CheckNodePresence may have just finished/advanced this tick

	local tDist = SkuNav:GetDistanceToWp(tCurrentTarget)
	if tDist and tDist <= ARRIVAL_RANGE then
		FinishCurrentTarget("arrived")
		return
	end

	-- Stuck check -- see its own comment above (near STUCK_CHECK_INTERVAL)
	-- for the full reasoning (measures actual player displacement now, not
	-- distance-to-target). Throttled to once per STUCK_CHECK_INTERVAL rather
	-- than every 0.15s tick -- "making progress" only means anything
	-- measured over several seconds.
	do
		local tNow = GetTime()
		if not tStuckLastCheckTime then tStuckLastCheckTime = tNow end
		if tNow - tStuckLastCheckTime >= STUCK_CHECK_INTERVAL then
			local tPlayerX, tPlayerY = UnitPosition("player")
			if tPlayerX and tStuckLastWorldX then
				local tMoved = SkuNav:Distance(tStuckLastWorldX, tStuckLastWorldY, tPlayerX, tPlayerY) or 0
				local tMoving = (GetUnitSpeed("player") or 0) > 0
				local tInCombat = UnitAffectingCombat and UnitAffectingCombat("player")
				local tOnTaxi = UnitOnTaxi and UnitOnTaxi("player")
				if tMoved < STUCK_MIN_PROGRESS and tMoving and not tInCombat and not tOnTaxi then
					if not tStuckAnnounced then
						Announce(Sku.deEn and Sku.deEn("Blockiert? Hindernis umgehen oder ueberspringen", "Stuck? Try going around, or skip this ore", "Bloqué ? Contournez l'obstacle ou sautez ce minerai") or "Bloqué ? Contournez l'obstacle ou sautez ce minerai")
						Log("WatchRouteProgress: stuck check -- only %.1fy actually moved in %ds toward '%s', announced.", tMoved, STUCK_CHECK_INTERVAL, tCurrentTarget)
						tStuckAnnounced = true
					end
				else
					tStuckAnnounced = false
				end
			end
			if tPlayerX then tStuckLastWorldX, tStuckLastWorldY = tPlayerX, tPlayerY end
			tStuckLastCheckTime = tNow
		end
	end
end

-- 0.15s -- fast enough that a manual skip (Ctrl+Shift+W, fallback mode) and
-- arrival detection both feel immediate rather than laggy; the check body
-- is a handful of table/string ops plus one distance calc, cheap at ~7
-- calls/sec.
local function StartRouteTicker()
	StopRouteTicker()
	tRouteTicker = C_Timer.NewTicker(0.15, WatchRouteProgress)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Starts (or restarts) a route. aCategory: RESOURCE_CATEGORIES.Mining or
-- .Herb. aTypeFilter: nil for every type in that category found nearby, or
-- {[gatherMateTypeId]=true} to restrict to one. aLabel is only used for the
-- announcement.
function SkuGatherRoute:StartRoute(aCategory, aTypeFilter, aLabel)
	aCategory = aCategory or RESOURCE_CATEGORIES.Mining
	if not IsGatherMatePresent() then
		Announce(Sku.deEn and Sku.deEn("GatherMate2 nicht geladen", "GatherMate2 not loaded", "GatherMate2 non chargé") or "GatherMate2 non chargé")
		return
	end
	if InCombatLockdown() then
		Announce(Sku.deEn and Sku.deEn("Nicht im Kampf möglich", "Not possible in combat", "Impossible en combat") or "Impossible en combat")
		return
	end

	-- Clear any previous run first -- ClearRouteWaypoints is idempotent/safe
	-- with nothing active.
	StopRouteTicker()
	ClearRouteWaypoints()
	tActiveCategory = aCategory

	local tNodes = ScanZoneNodes(aCategory, aTypeFilter)
	if #tNodes == 0 then
		Announce(Sku.deEn and Sku.deEn("Keine Knoten gefunden", "No nodes found", "Aucun nœud trouvé") or "Aucun nœud trouvé")
		Log("StartRoute: 0 nodes found (db=%s filter=%s). Reminder: GatherMate2 data must be imported via its own Options -> Import tab.", aCategory.dbGlobal, aTypeFilter and "set" or "all")
		return
	end

	local tPlayerX, tPlayerY = UnitPosition("player")
	local tPName = UnitName("player")
	local tTime = GetTime()

	local tClosestName, tClosestDist
	for i, tNode in ipairs(tNodes) do
		local tName = aCategory.baseName .. ";" .. i
		SkuNav:SetWaypoint(tName, {
			contintentId = tNode.contintentId,
			areaId = tNode.areaId,
			worldX = tNode.worldX,
			worldY = tNode.worldY,
			createdAt = tTime,
			createdBy = tPName,
			size = 1,
		}, true) -- temp waypoint: regenerable data, never persisted to SkuDB
		tActiveRouteNames[#tActiveRouteNames + 1] = tName
		tActiveRouteNameSet[tName] = true
		tActiveRouteNodeName[tName] = ResourceTypeName(aCategory, tNode.typeId)
		tActiveRouteNodeIdentity[tName] = { uiMapId = tNode.uiMapId, coordId = tNode.coordId }

		if tPlayerX then
			local tDist = SkuNav:Distance(tPlayerX, tPlayerY, tNode.worldX, tNode.worldY)
			if tDist and (not tClosestDist or tDist < tClosestDist) then
				tClosestDist = tDist
				tClosestName = tName
			end
		end
	end

	if not tClosestName then
		-- UnitPosition failed (should not happen while not in an instance
		-- transition) -- fall back to the first created node so the route
		-- still starts rather than silently doing nothing.
		tClosestName = tActiveRouteNames[1]
	end

	AdvanceToTarget(tClosestName)
	StartRouteTicker()

	Announce((aLabel or aCategory.baseName) .. " " .. #tNodes .. " " .. (Sku.deEn and Sku.deEn("Knoten", "nodes", "nœuds") or "nœuds"))
	Log("StartRoute: db=%s started with %d node(s), first target='%s'.", aCategory.dbGlobal, #tNodes, tClosestName)
end

function SkuGatherRoute:StopRoute()
	StopRouteTicker()
	local tHadNodes = #tActiveRouteNames > 0
	ClearRouteWaypoints()
	SkuNav.isAutoSelectEnabled = false
	SkuNav:EndFollowingWpOrRt()
	if tHadNodes then
		Announce(Sku.deEn and Sku.deEn("Abbauroute gestoppt", "Gather route stopped", "Route de minage arrêtée") or "Route de minage arrêtée")
	end
	Log("StopRoute: stopped, hadNodes=%s.", tostring(tHadNodes))
end

-- [2026-08-18] A GUARANTEED-reliable "abandon this node, move to the next
-- one" -- requested after Ctrl+Shift+W (SKU_KEY_MOVETONEXTWP) turned out not
-- to reach the actual target reliably from the last leg of a close route
-- (native metaroute stepping only advances one PATH HOP per press, which
-- needs a precise number of presses to actually pass the final node -- easy
-- to mis-count without being able to see the map). This does not touch
-- SkuNav.MoveToWp or metaroute state via a keypress at all -- it calls
-- FinishCurrentTarget directly, so it works identically regardless of
-- whether the current leg is a real close route or the plain-waypoint
-- fallback, and regardless of how far into either the player currently is.
-- Reachable two ways, per "corrige ça ou ajoute une autre combinaison de
-- touche configurable": the "Sauter ce minerai" menu entry below (always
-- available, no setup needed), and a dedicated keybind (Bindings.xml,
-- auto-bound to Ctrl+Shift+N on first load if that key is free -- see
-- OnEnable -- and reconfigurable via Blizzard's own Key Bindings panel,
-- under "Sku - Route de minage", same as any other addon keybind).
function SkuGatherRoute:SkipCurrentTarget()
	if not tCurrentTarget then
		Announce(Sku.deEn and Sku.deEn("Keine aktive Route", "No active route", "Aucune route active") or "Aucune route active")
		return
	end
	FinishCurrentTarget("manual-skip-dedicated")
end

-- [2026-08-18] "Combien il en reste" -- speaks the active category, how
-- many nodes are left, and what's currently being navigated to, without
-- needing to check /sgrlog. Safe to call any time, active route or not.
function SkuGatherRoute:AnnounceStatus()
	if not tCurrentTarget then
		Announce(Sku.deEn and Sku.deEn("Keine aktive Route", "No active route", "Aucune route active") or "Aucune route active")
		return
	end
	local tCurrentName = tActiveRouteNodeName[tCurrentTarget]
		or (Sku.deEn and Sku.deEn("unbekannt", "unknown", "inconnu") or "inconnu")
	Announce(tActiveCategory.baseName .. ", " .. #tActiveRouteNames .. " "
		.. (Sku.deEn and Sku.deEn("restlich", "remaining", "restants") or "restants") .. ", "
		.. (Sku.deEn and Sku.deEn("Ziel", "target", "cible") or "cible") .. " " .. tCurrentName)
end

-- [2026-08-18] Thin wrapper so Bindings.xml (which can only reference plain
-- method names, not local upvalues like RESOURCE_CATEGORIES) can start a
-- route by category-key string ("Mining"/"Herb") from a keybind, using the
-- same defaults StartRoute's own callers already use (nil type filter = every
-- type nearby, category's own baseName as the announced label).
function SkuGatherRoute:StartRouteKeybind(aCategoryKey)
	local tCategory = RESOURCE_CATEGORIES[aCategoryKey]
	if not tCategory then return end
	SkuGatherRoute:StartRoute(tCategory, nil, tCategory.baseName)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Shift+F1 menu: "Route de minage" appended at the very end of Sku's root
-- menu (table.insert onto the LIVE SkuMenu.rootLayout array -- never calling
-- SkuMenu:SetRootLayout, which would REPLACE the whole list and wipe every
-- one of Sku's own root entries). Uses SkuMenu:BuildNode/Build (SkuZOptions/
-- SkuMenu.lua), the declarative helper that file's own header comment
-- invites new modules to use, instead of hand-rolling InjectMenuItems calls.
-- Generic "choose one type" submenu -- used for both the mining and herb
-- "choose one" entries below, parameterized by category.
local function BuildTypeSubmenu(aCategory, aEntry)
	local tTypes = GetPresentTypesInZone(aCategory)
	if #tTypes == 0 then
		SkuMenu:Build(aEntry, {
			{ kind = "action",
			  label = function() return Sku.deEn and Sku.deEn("Nichts hier gefunden", "Nothing found here", "Rien trouvé ici") or "Rien trouvé ici" end,
			  run = function() end },
		})
		return
	end
	local tSpecs = {}
	for _, tType in ipairs(tTypes) do
		local tTypeId, tName = tType.typeId, tType.name
		tSpecs[#tSpecs + 1] = {
			kind = "action",
			label = tName,
			run = function() SkuGatherRoute:StartRoute(aCategory, { [tTypeId] = true }, tName) end,
		}
	end
	SkuMenu:Build(aEntry, tSpecs)
end

-- Registers one category's full menu section (Shift+F1 -> "Route de
-- minage" / "Route d'herbes") under aModuleId, appended at the end of the
-- root menu. Import and the minimap-icon toggle are duplicated into BOTH
-- sections (cheap, and neither the user nor GatherMate2 cares which
-- category asked) so either entry point is self-sufficient -- a user who
-- only ever cares about herbs should never need to remember "go to the
-- mining menu first".
-- Forward-declared: BuildKeybindsSubmenu is DEFINED further down (after
-- InstallDefaultKeybind, near OnEnable), but referenced here inside
-- InstallCategoryMenu's menu spec below. That reference only actually RUNS
-- when the player opens the "Raccourcis clavier" entry at menu-open time --
-- well after the real function body below has executed and assigned this
-- upvalue -- so the forward declaration just needs to exist syntactically
-- for the closure captured here to resolve correctly later.
local BuildKeybindsSubmenu

local function InstallCategoryMenu(aCategory, aModuleId, aLabelFn)
	SkuMenu:RegisterModule(aModuleId, {
		label = aLabelFn,
		build = function(entry)
			SkuMenu:Build(entry, {
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("GatherMate2-Daten importieren", "Import GatherMate2 data", "Importer les données GatherMate2") or "Importer les données GatherMate2" end,
				  run = function() ImportGatherMateData() end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("GatherMate2-Minikartensymbole an/aus", "GatherMate2 minimap icons on/off", "Icônes minicarte GatherMate2 activées/désactivées") or "Icônes minicarte GatherMate2 activées/désactivées" end,
				  run = function() ToggleGatherMateMinimapIcons() end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("Alle starten", "Start: all", "Démarrer : tout") or "Démarrer : tout" end,
				  run = function() SkuGatherRoute:StartRoute(aCategory, nil, aLabelFn()) end },
				{ kind = "list",
				  label = function() return Sku.deEn and Sku.deEn("Einen Typ waehlen", "Choose one type", "Choisir un type") or "Choisir un type" end,
				  build = function(subEntry) BuildTypeSubmenu(aCategory, subEntry) end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("Ueberspringen", "Skip this one", "Sauter celui-ci") or "Sauter celui-ci" end,
				  run = function() SkuGatherRoute:SkipCurrentTarget() end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("Route stoppen", "Stop route", "Arrêter la route") or "Arrêter la route" end,
				  run = function() SkuGatherRoute:StopRoute() end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("Status", "Status", "État de la route") or "État de la route" end,
				  run = function() SkuGatherRoute:AnnounceStatus() end },
				{ kind = "list",
				  label = function() return Sku.deEn and Sku.deEn("Erkennungsreichweite", "Detection range", "Portée de détection") or "Portée de détection" end,
				  build = function(subEntry)
					SkuMenu:Build(subEntry, {
						{ kind = "action", label = "25m", run = function() SetPresenceCheckRange(25) end },
						{ kind = "action", label = "50m", run = function() SetPresenceCheckRange(50) end },
						{ kind = "action", label = "75m", run = function() SetPresenceCheckRange(75) end },
						{ kind = "action", label = "100m", run = function() SetPresenceCheckRange(100) end },
					})
				  end },
				{ kind = "list",
				  label = function() return Sku.deEn and Sku.deEn("Tastenkombinationen", "Keyboard shortcuts", "Raccourcis clavier") or "Raccourcis clavier" end,
				  build = function(subEntry) BuildKeybindsSubmenu(subEntry) end },
				{ kind = "action",
				  label = function() return Sku.deEn and Sku.deEn("Erinnerung an besuchte Knoten loeschen", "Clear recent-node memory", "Vider la mémoire des nœuds récents") or "Vider la mémoire des nœuds récents" end,
				  run = function() ClearRecentNodeMemory() end },
			})
		end,
	})
	local tAlreadyThere = false
	for i = 1, #SkuMenu.rootLayout do
		if SkuMenu.rootLayout[i] == aModuleId then tAlreadyThere = true break end
	end
	if not tAlreadyThere then
		table.insert(SkuMenu.rootLayout, aModuleId)
	end
	Log("InstallCategoryMenu: '%s' root menu entry installed (already present=%s).", aModuleId, tostring(tAlreadyThere))
end

local function InstallMenu()
	if not SkuMenu or not SkuMenu.RegisterModule or not SkuMenu.rootLayout then
		Log("InstallMenu: SkuMenu not available, skipped.")
		return
	end
	InstallCategoryMenu(RESOURCE_CATEGORIES.Mining, "SkuGatherRoute",
		function() return Sku.deEn and Sku.deEn("Abbauroute", "Gather route", "Route de minage") or "Route de minage" end)
	-- [2026-08-18, secondary priority] Herb route, appended right after
	-- mining as its own root entry -- same reasoning as everything else in
	-- this file: additive only, shares the whole route engine, never
	-- touches Sku's own files.
	InstallCategoryMenu(RESOURCE_CATEGORIES.Herb, "SkuGatherRouteHerb",
		function() return Sku.deEn and Sku.deEn("Kräuterroute", "Herb route", "Route d'herbes") or "Route d'herbes" end)
end

-- [2026-08-18] Sku's OWN keybinds (SKU_KEY_*, SkuZOptions/SkuKeyBinds.lua)
-- are NOT plain SetBinding entries -- Sku applies them via
-- SetOverrideBindingClick on secure buttons (SkuCore/Options.lua's
-- SkuKeyBindsUpdate/rebind machinery), a SEPARATE binding layer that WoW
-- always checks BEFORE normal SetBinding-based bindings for the same
-- physical key. GetBindingAction/GetBindingKey (used elsewhere in this file)
-- are blind to that layer entirely. Confirmed the hard way in
-- SkuBagnonBridge (a companion addon, same author/pattern): its original
-- Ctrl+Shift+B default collided with Sku's own SKU_KEY_ROLLNEED override
-- binding, producing a binding that LOOKED correctly saved (GetBindingKey
-- confirmed it) but the key never actually reached it. Ctrl+Shift+N (this
-- addon's own default) is confirmed free against Sku's SkuKeyBinds.lua full
-- default list, so it isn't affected -- but this check is added defensively
-- for whatever key the player picks for the OTHER 4 actions via the
-- Raccourcis clavier menu below, checked against Sku's own LIVE keybind
-- table (SkuOptions:SkuKeyBindsCheckBound), not just its hardcoded defaults.
local function tSkuOwnBindingOwner(aKey)
	if not SkuOptions or not SkuOptions.SkuKeyBindsCheckBound then return nil end
	local tOk, tResult = pcall(SkuOptions.SkuKeyBindsCheckBound, SkuOptions, aKey)
	if tOk then return tResult end
	return nil
end

-- Auto-binds the dedicated skip keybind (Bindings.xml declares the
-- SKUGATHERROUTE_SKIP action; this just gives it a default key the first
-- time it's ever seen unbound, so it works immediately without a trip
-- through Blizzard's Key Bindings panel). Never overwrites an existing
-- binding -- if SKUGATHERROUTE_SKIP is already bound (to anything, even a
-- key the user picked themselves later), or if the default key is already
-- claimed by something else (Sku's own override layer included), this
-- leaves things alone; the "Sauter ce minerai" menu entry always works
-- regardless, no keybind required.
local function InstallDefaultKeybind()
	local tExisting = GetBindingKey("SKUGATHERROUTE_SKIP")
	if tExisting then
		Log("InstallDefaultKeybind: already bound to '%s', leaving as-is.", tExisting)
		return
	end
	local tDefaultKey = "CTRL-SHIFT-N"
	local tSkuOwner = tSkuOwnBindingOwner(tDefaultKey)
	if tSkuOwner then
		Log("InstallDefaultKeybind: default key '%s' already used by Sku's own '%s' -- left unbound (configurable via Key Bindings -> Sku - Route de minage, or the addon's own Raccourcis clavier menu).", tDefaultKey, tSkuOwner)
		return
	end
	local tClaimedBy = GetBindingAction(tDefaultKey)
	if tClaimedBy ~= nil and tClaimedBy ~= "" then
		Log("InstallDefaultKeybind: default key '%s' already used by '%s' -- left unbound (configurable via Key Bindings -> Sku - Route de minage).", tDefaultKey, tClaimedBy)
		return
	end
	SetBinding(tDefaultKey, "SKUGATHERROUTE_SKIP")
	SaveBindings(GetCurrentBindingSet())
	Log("InstallDefaultKeybind: bound '%s' to SKUGATHERROUTE_SKIP.", tDefaultKey)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [2026-08-18] "Rajoute un menu pour ajouter des raccourcis clavier aux
-- fonctions... dans le sous-menu Shift+F1" -- a keybind-configuration
-- submenu reachable from Sku's own accessible menu, not only Blizzard's Key
-- Bindings panel (which still works too -- both read/write the exact same
-- underlying bindings, this is just a second, more discoverable way in).
--
-- Deliberately its OWN small capture routine (EnableKeyboard/OnKeyDown) via
-- plain Blizzard SetBinding/GetBindingKey/SaveBindings, rather than hooking
-- into Sku's own internal SkuOptions.skuDefaultKeyBindings/SkuKeyBinds
-- system (SkuZOptions/SkuKeyBinds.lua + SkuCore/Options.lua's ~2500-line
-- rebind machinery). That system IS technically extensible from outside
-- (skuDefaultKeyBindings is a plain global table; SkuCore/Options.lua's
-- "loose entries" loop -- "everything not in a group" -- would even surface
-- a foreign entry automatically) but every entry's displayed NAME is read
-- unconditionally as L[bindingConst] straight out of Sku's OWN AceLocale
-- table with no nil-safe fallback anywhere in that code path -- an addon
-- adding a constant Sku's locale files don't know about risks a hard Lua
-- error ("attempt to concatenate a nil value") the next time that menu
-- section is opened, for a client on any locale other than Sku's own
-- default. Not a risk worth taking against a screen-reader user's own menu.
-- This local implementation touches nothing outside this addon's own files.
local tKeyCaptureFrame

-- Keys that mean "still deciding", not "this is the binding" -- a bare
-- modifier press must not itself become the assigned key (CTRL-SHIFT-N's
-- capture, for instance, would otherwise resolve to plain "CTRL" the instant
-- Control is pressed, before Shift+N ever comes down).
local tModifierOnlyKeys = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
	UNKNOWN = true,
}

local function tModifierPrefix()
	local tPrefix = ""
	if IsControlKeyDown() then tPrefix = tPrefix .. "CTRL-" end
	if IsAltKeyDown() then tPrefix = tPrefix .. "ALT-" end
	if IsShiftKeyDown() then tPrefix = tPrefix .. "SHIFT-" end
	return tPrefix
end

-- Captures the next physical key pressed and binds it to aBindingName
-- (a Blizzard binding action name, e.g. "SKUGATHERROUTE_SKIP"). ESCAPE
-- cancels without changing anything. aOnDone(aFullKeyOrNil) is called once
-- the capture ends either way, so the caller can refresh its own menu label.
-- If the physical key was already claimed by something else, that OTHER
-- binding is cleared first (SetBinding(key, nil)) -- otherwise the two
-- actions would silently fight over the same key with no obvious symptom
-- beyond "it stopped working", which is exactly the kind of thing a blind
-- player cannot casually notice by glancing at a rebind screen.
local function CaptureKeyFor(aBindingName, aOnDone)
	if not tKeyCaptureFrame then
		tKeyCaptureFrame = CreateFrame("Frame", nil, UIParent)
		tKeyCaptureFrame:SetPropagateKeyboardInput(false)
		tKeyCaptureFrame:Hide()
	end
	tKeyCaptureFrame:SetScript("OnKeyDown", function(aSelf, aKey)
		if tModifierOnlyKeys[aKey] then return end
		aSelf:EnableKeyboard(false)
		aSelf:Hide()
		if aKey == "ESCAPE" then
			Log("CaptureKeyFor: cancelled for %s.", aBindingName)
			if aOnDone then aOnDone(nil) end
			return
		end
		local tFullKey = tModifierPrefix() .. aKey

		-- Sku's own override-bound keys can NEVER be reached by a normal
		-- SetBinding here (see tSkuOwnBindingOwner's own comment above) --
		-- refuse outright rather than silently save a binding that will
		-- never fire.
		local tSkuOwner = tSkuOwnBindingOwner(tFullKey)
		if tSkuOwner then
			local tSkuOwnerName = (_G["BINDING_NAME_" .. tSkuOwner]) or tSkuOwner
			Log("CaptureKeyFor: '%s' is already used by Sku's own '%s' (override binding) -- refused.", tFullKey, tSkuOwner)
			Announce((Sku.deEn and Sku.deEn("Bereits von Sku belegt: ", "Already used by Sku: ", "Déjà utilisée par Sku : ") or "Déjà utilisée par Sku : ") .. tSkuOwnerName)
			if aOnDone then aOnDone(nil) end
			return
		end

		local tPrevOwner = GetBindingAction(tFullKey)
		if tPrevOwner and tPrevOwner ~= "" and tPrevOwner ~= aBindingName then
			SetBinding(tFullKey, nil)
			Log("CaptureKeyFor: '%s' was bound to '%s', cleared to avoid a silent conflict.", tFullKey, tPrevOwner)
		end
		SetBinding(tFullKey, aBindingName)
		SaveBindings(GetCurrentBindingSet())
		Log("CaptureKeyFor: bound '%s' to %s.", tFullKey, aBindingName)
		if aOnDone then aOnDone(tFullKey) end
	end)
	tKeyCaptureFrame:EnableKeyboard(true)
	tKeyCaptureFrame:Show()
	Announce(Sku.deEn and Sku.deEn("Neue Taste druecken oder Escape zum Abbrechen", "Press a new key, or Escape to cancel", "Appuyez sur une nouvelle touche, ou Echap pour annuler") or "Appuyez sur une nouvelle touche, ou Echap pour annuler")
end

-- "Ctrl+Shift+N", or "Aucune"/"none"/"keine" if unbound. GetBindingKey
-- returns up to two physical keys for one action; both are shown when
-- present (mirrors Sku's own two-slot key1/key2 display elsewhere).
local function FriendlyBoundKeys(aBindingName)
	local tKey1, tKey2 = GetBindingKey(aBindingName)
	local tNone = Sku.deEn and Sku.deEn("keine", "none", "aucune") or "aucune"
	if not tKey1 and not tKey2 then return tNone end
	if tKey1 and tKey2 then return tKey1 .. " / " .. tKey2 end
	return tKey1 or tKey2
end

-- One entry per keybindable action this addon exposes. label3 is used both
-- for the submenu row and (via BINDING_NAME_<bindingName>, set at the top of
-- this file) for Blizzard's own Key Bindings panel -- kept here too so the
-- submenu row text doesn't silently drift from that name over time.
local KEYBIND_ACTIONS = {
	{ bindingName = "SKUGATHERROUTE_SKIP", label = function() return BINDING_NAME_SKUGATHERROUTE_SKIP end },
	{ bindingName = "SKUGATHERROUTE_STARTMINING", label = function() return BINDING_NAME_SKUGATHERROUTE_STARTMINING end },
	{ bindingName = "SKUGATHERROUTE_STARTHERB", label = function() return BINDING_NAME_SKUGATHERROUTE_STARTHERB end },
	{ bindingName = "SKUGATHERROUTE_STOP", label = function() return BINDING_NAME_SKUGATHERROUTE_STOP end },
	{ bindingName = "SKUGATHERROUTE_STATUS", label = function() return BINDING_NAME_SKUGATHERROUTE_STATUS end },
}

-- One shared "Raccourcis clavier" submenu, listed under BOTH the mining and
-- herb menu sections (InstallCategoryMenu below) so it's reachable no matter
-- which one the player opens first -- it always lists the SAME 5 actions
-- (this addon has one keybind namespace, not one per category).
BuildKeybindsSubmenu = function(aEntry)
	local tSpecs = {}
	for _, tAction in ipairs(KEYBIND_ACTIONS) do
		local tBindingName = tAction.bindingName
		tSpecs[#tSpecs + 1] = {
			kind = "list",
			label = function() return tAction.label() .. " : " .. FriendlyBoundKeys(tBindingName) end,
			build = function(aSubEntry)
				SkuMenu:Build(aSubEntry, {
					{ kind = "action",
					  label = function() return Sku.deEn and Sku.deEn("Neu belegen", "Assign new key", "Assigner une nouvelle touche") or "Assigner une nouvelle touche" end,
					  run = function()
						CaptureKeyFor(tBindingName, function(aNewKey)
							if aNewKey then
								Announce((Sku.deEn and Sku.deEn("Neue Taste", "New key", "Nouvelle touche") or "Nouvelle touche") .. " " .. aNewKey)
							end
						end)
					  end },
					{ kind = "action",
					  label = function() return Sku.deEn and Sku.deEn("Belegung loeschen", "Clear binding", "Supprimer la touche") or "Supprimer la touche" end,
					  run = function()
						local tKey1, tKey2 = GetBindingKey(tBindingName)
						if not tKey1 and not tKey2 then return end
						if tKey1 then SetBinding(tKey1, nil) end
						if tKey2 then SetBinding(tKey2, nil) end
						SaveBindings(GetCurrentBindingSet())
						Log("BuildKeybindsSubmenu: cleared binding for %s.", tBindingName)
						Announce(Sku.deEn and Sku.deEn("Belegung geloescht", "Binding cleared", "Touche supprimée") or "Touche supprimée")
					  end },
				})
			end,
		}
	end
	SkuMenu:Build(aEntry, tSpecs)
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuGatherRoute:OnEnable()
	Log("OnEnable start.")
	local tPresent = IsGatherMatePresent()
	Log("IsGatherMatePresent() = %s", tostring(tPresent))

	local tOk, tErr = pcall(InstallMenu)
	if not tOk then Log("InstallMenu THREW: %s", tostring(tErr)) end

	local tOkKb, tErrKb = pcall(InstallDefaultKeybind)
	if not tOkKb then Log("InstallDefaultKeybind THREW: %s", tostring(tErrKb)) end

	local tOkPrune, tErrPrune = pcall(PruneRecentNodeMemory)
	if not tOkPrune then Log("PruneRecentNodeMemory THREW: %s", tostring(tErrPrune)) end

	self:RegisterChatCommand("sgr", "SlashCommand")
	self:RegisterChatCommand("skugatherroute", "SlashCommand")

	if not tPresent then
		print("|cffff8800GatherMate2 SKU Access|r: " ..
			(Sku.deEn and Sku.deEn(
				"GatherMate2 nicht gefunden. Aktiv, aber inaktiv, bis GatherMate2 geladen ist.",
				"GatherMate2 not found. Enabled, but inactive until GatherMate2 is loaded.",
				"GatherMate2 introuvable. Actif, mais inactif tant que GatherMate2 n'est pas chargé.")
			or "GatherMate2 introuvable."))
	else
		print("|cff00ff00GatherMate2 SKU Access|r: " ..
			(Sku.deEn and Sku.deEn("aktiv. Menü: Local -> Abbauroute / Kräuterroute.", "active. Menu: Local -> Gather route / Herb route.", "actif. Menu : Local -> Route de minage / Route d'herbes.")
			or "actif. Menu : Local -> Route de minage / Route d'herbes."))
	end
	Log("OnEnable end.")
end

function SkuGatherRoute:OnDisable()
	StopRouteTicker()
	ClearRouteWaypoints()
	Log("OnDisable.")
end

-- /sgr [all|herb|stop|skip|status|import] -- mainly for testing without going
-- through the menu. Bare /sgr or /sgr all = mining (unchanged default, for
-- anyone already used to it); /sgr herb = herbs.
function SkuGatherRoute:SlashCommand(aMsg)
	aMsg = (aMsg or ""):lower():match("^%s*(.-)%s*$")
	if aMsg == "stop" then
		SkuGatherRoute:StopRoute()
	elseif aMsg == "import" then
		ImportGatherMateData()
	elseif aMsg == "skip" then
		SkuGatherRoute:SkipCurrentTarget()
	elseif aMsg == "status" then
		SkuGatherRoute:AnnounceStatus()
	elseif aMsg == "herb" or aMsg == "herbs" then
		SkuGatherRoute:StartRoute(RESOURCE_CATEGORIES.Herb, nil,
			Sku.deEn and Sku.deEn("Kräuterroute", "Herb route", "Route d'herbes") or "Route d'herbes")
	else
		SkuGatherRoute:StartRoute(RESOURCE_CATEGORIES.Mining, nil,
			Sku.deEn and Sku.deEn("Abbauroute", "Gather route", "Route de minage") or "Route de minage")
	end
end
