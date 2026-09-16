import Quickshell
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Io
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Ui

// Steam quick-launcher: a single, always-visible bar icon replacing Steam's
// own left-click (which its Linux client never implements -- confirmed via
// D-Bus, only its right-click context menu works) with a popup listing your
// installed games -- box art + blurb from Steam's free/keyless CDN and
// store API, sorted by last-played (from Steam's own local play-history
// file), one click to launch. Right-click still gives Steam's real native
// menu (Store/Library/Friends/Settings/Exit) as a fallback, when Steam is
// actually running to provide one. The icon and popup work identically
// whether Steam is running or not (all data comes from local files and
// steam:// URIs that launch Steam if needed); only when Steam isn't
// installed at all does the popup show an explanatory empty state instead
// of a games list.
BarWidget {
  id: root
  moduleName: "io.github.alanone.steam-launcher"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int trayItemExtent: Style.bar.iconSlot

  // Matches by substring across id/title/tooltipTitle rather than an exact
  // id compare -- confirmed necessary this session: Quickshell doesn't
  // reliably expose a tray item's raw D-Bus Id as a stable, predictable
  // `.id` string.
  function itemNamed(item, name) {
    if (!item) return false
    var needle = String(name || "").toLowerCase()
    var text = function(v) { return String(v || "").toLowerCase() }
    return text(item.id).indexOf(needle) !== -1
      || text(item.title).indexOf(needle) !== -1
      || text(item.tooltipTitle).indexOf(needle) !== -1
  }

  readonly property var steamItem: {
    var values = SystemTray.items.values
    for (var i = 0; i < values.length; i++) {
      var item = values[i]
      if (item.status === Status.Passive) continue
      if (itemNamed(item, "steam")) return item
    }
    return null
  }

  // Always visible now, regardless of whether Steam is installed or
  // running -- Alan's call: a missing/not-yet-running Steam should still
  // show the icon and explain itself in the popup, rather than the icon
  // just not being there with no explanation. Steam being *running* only
  // changes where the icon image and native right-click menu come from
  // (see steamItem/steamInstalled below); the games list, launching, etc.
  // all come from local files and steam:// URIs that work either way.
  visible: true
  implicitWidth: root.trayItemExtent
  implicitHeight: root.trayItemExtent

  // Checked once at startup (installing/uninstalling Steam itself isn't
  // something that happens mid-session) against the same two locations
  // scripts/list-installed-games.sh already globs -- a plain directory
  // check, not a games count, so "installed with zero games" and "not
  // installed" are distinguishable. Defaults optimistic (true) so a slow
  // check doesn't flash a wrong "not installed" message before it resolves.
  property bool steamInstalled: true

  Process {
    id: steamInstalledCheckProc
    command: ["bash", "-c", "test -d \"$HOME/.local/share/Steam\" -o -d \"$HOME/.steam/steam\" && echo yes || echo no"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.steamInstalled = text.trim() === "yes"
    }
  }

  property bool trayMenuOpen: false
  property var activeTrayItem: null
  property var activeTrayAnchor: null

  property bool steamPopupOpen: false
  property var steamPopupAnchor: null
  property var steamGames: []
  property bool steamGamesLoading: false
  property bool steamGamesLoaded: false
  property var steamGamesPending: null

  // Rescanning cadence: a full rescan on every single popup open was needless
  // churn for data that rarely changes moment-to-moment (Alan's feedback).
  // Instead: a cheap mtime-based change check (a handful of stat() calls, not
  // the VDF/binary parsing the real rescan does) on a short interval, running
  // in the background regardless of whether the popup is open, so data is
  // already warm by the time it's opened. A longer fallback interval forces a
  // full rescan periodically even if the cheap check somehow misses a change.
  // 5 minutes / 3 hours are reasonable defaults for a personal desktop
  // widget, not load-bearing precise numbers -- installing a game and wanting
  // to see it appear within a few minutes felt right; anything shorter buys
  // little for the extra stat() calls, anything longer starts to feel stale.
  property string steamDataSignature: ""
  property double steamLastFullScanAt: 0
  readonly property int steamChangeCheckIntervalMs: 5 * 60 * 1000
  readonly property int steamFullScanFallbackMs: 3 * 60 * 60 * 1000

  Timer {
    id: steamChangeCheckTimer
    interval: root.steamChangeCheckIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.checkSteamDataForChanges()
  }

  Process {
    id: steamDataSignatureProc
    // Concatenated mtimes of everything the installed-games rescan actually
    // depends on: the steamapps dir (install/uninstall adds or removes an
    // appmanifest_*.acf), localconfig.vdf (last-played/playtime updates),
    // and the achievement stat cache dir (new achievement data). A changed
    // signature means "worth paying for a real rescan"; an unchanged one
    // means the expensive parsing below can be skipped entirely.
    command: ["bash", "-c",
      "for p in \"$HOME/.local/share/Steam/steamapps\" \"$HOME/.local/share/Steam/appcache/stats\" \"$HOME\"/.local/share/Steam/userdata/*/config/localconfig.vdf; do stat -c '%Y' \"$p\" 2>/dev/null; done | tr '\\n' ','"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamDataSignature(text)
    }
  }

  function checkSteamDataForChanges() {
    if (!steamDataSignatureProc.running) steamDataSignatureProc.running = true
  }

  function onSteamDataSignature(raw) {
    var sig = String(raw || "").trim()
    var now = Date.now()
    var overdue = (now - root.steamLastFullScanAt) >= root.steamFullScanFallbackMs
    var changed = root.steamDataSignature !== "" && sig !== root.steamDataSignature
    root.steamDataSignature = sig
    if ((!root.steamGamesLoaded || changed || overdue) && !root.steamGamesLoading) loadSteamGames()
  }

  // "installed" or "notinstalled" -- which tab is showing below the search
  // bar. The search query is intentionally shared/not reset when switching
  // tabs (typing a name, not finding it installed, then checking the other
  // tab keeps the same filter applied -- more useful than surprising).
  property string steamActiveTab: "installed"

  // Search box state. Filtering is a pure client-side name match over the
  // already-loaded list -- no rescan, no process spawn -- so it can just be
  // a computed property re-evaluated on every keystroke.
  property string steamSearchQuery: ""
  readonly property var filteredSteamGames: {
    var q = steamSearchQuery.trim().toLowerCase()
    if (!q) return steamGames
    return steamGames.filter(function(g) { return g.name.toLowerCase().indexOf(q) !== -1 })
  }
  readonly property var filteredSteamNotInstalled: {
    var q = steamSearchQuery.trim().toLowerCase()
    if (!q) return steamNotInstalled
    return steamNotInstalled.filter(function(g) { return g.name.toLowerCase().indexOf(q) !== -1 })
  }

  // Disk usage always reflects the full install list, not the filtered one
  // -- "how much disk am I using" shouldn't change just because a search is
  // active.
  readonly property real totalDiskBytes: {
    var sum = 0
    for (var i = 0; i < steamGames.length; i++) sum += (steamGames[i].sizeOnDisk || 0)
    return sum
  }

  // Owned-but-not-installed games: collapsed and unloaded by default. The
  // scan is a real ~0.25s (parsing a multi-MB appinfo.vdf in Python, unlike
  // the other sub-millisecond-scale local reads this popup already does on
  // every open), and most opens are "launch something already installed" --
  // paying that cost eagerly on every single open for a section most opens
  // never look at isn't worth it. Loaded once on first expand, then kept
  // for the rest of the session (owned/installed status doesn't change
  // often enough to justify rescanning every popup open the way the
  // installed list does).
  property var steamNotInstalled: []
  property var steamNotInstalledPending: null
  property bool steamNotInstalledLoading: false
  property bool steamNotInstalledLoaded: false

  // Persisted to disk (not just in-memory-for-the-session): parsing
  // appinfo.vdf plus the last-played/achievements scans is real work
  // (~0.25s+) worth skipping entirely on a cache hit, not just avoiding a
  // second parse within the same shell session. Ownership/names change
  // rarely; a day-old cache is still accurate almost all the time.
  property var steamNotInstalledCache: ({})
  readonly property int steamNotInstalledCacheMaxAgeSec: 24 * 60 * 60

  // Descriptions/tags for not-installed games go through a strict
  // concurrency-limited queue instead of firing one curl process per game
  // immediately (the installed-games pattern) -- there can be *hundreds* of
  // owned-but-uninstalled games (537 on this machine), and firing that many
  // concurrent requests at Steam's store API would very plausibly trigger
  // the same rate-limiting this exact endpoint has already hit multiple
  // times this session from far lighter use. Installed games don't need
  // this: that list is naturally small (tens, not hundreds).
  property var steamNotInstalledFetchQueue: []
  property int steamNotInstalledFetchInFlight: 0
  readonly property int steamNotInstalledFetchConcurrency: 3

  // Persisted across shell restarts (the shell process itself restarts far
  // more often than a game's store blurb changes -- suspend/resume can
  // SIGKILL and relaunch it, `omarchy restart shell`, plugin hot-reloads,
  // logout/login -- so an in-memory-only cache would refetch from Steam's
  // API on nearly every restart). Loaded once from descriptionCacheFile
  // below; a description younger than descriptionCacheMaxAgeSec is served
  // straight from here with no network call at all.
  property var descriptionCache: ({})
  readonly property int descriptionCacheMaxAgeSec: 30 * 24 * 60 * 60

  // Submenu drill-down state for Steam's own right-click menu.
  // QsMenuEntry.display() renders a *platform* menu, which Quickshell
  // refuses unless the shell root sets `//@ pragma UseQApplication` -
  // omarchy's shell.qml does not, so every submenu click was a silent
  // no-op ("Cannot display PlatformMenuEntry as quickshell was not started
  // in QApplication mode" in the shell log). QsMenuEntry inherits
  // QsMenuHandle, so a child entry can feed a nested QsMenuOpener and
  // render inside this popup instead of going through the platform. Each
  // level keeps its own live opener: a child entry is owned by its parent
  // opener's model, so collapsing the stack to a single opener would
  // destroy the very entry being displayed (submenu turns up empty).
  property var submenuStack: []
  readonly property int submenuDepth: submenuStack.length
  readonly property string currentTitle: submenuDepth > 0 ? submenuStack[submenuDepth - 1].title : ""
  readonly property var currentChildren: submenuDepth > 0
    ? submenuStack[submenuDepth - 1].opener.children
    : trayMenuOpener.children

  // Changing level rebuilds the row delegates synchronously, so the next
  // row lands under a cursor that hasn't moved. Submenu clicks used to be
  // silent no-ops, which trained users to click them twice, and that second
  // click would now fire whatever entry took the spot. Ignore row clicks for
  // a beat after each level change; a deliberate follow-up click is slower.
  property bool menuLevelSettling: false

  Component {
    id: submenuOpenerComponent
    QsMenuOpener {}
  }

  Timer {
    id: menuLevelSettleTimer
    interval: 250
    onTriggered: root.menuLevelSettling = false
  }

  function settleMenuLevel() {
    menuLevelSettling = true
    menuLevelSettleTimer.restart()
  }

  function resetTrayMenu() {
    menuLevelSettling = false
    menuLevelSettleTimer.stop()
    // Flickable keeps its offset across a model swap whenever the new content
    // is still tall enough to hold it, so a menu dismissed while scrolled
    // would otherwise reopen part-way down with its first entries off screen.
    trayMenuFlick.contentY = 0
    // Clear the reactive stack before tearing anything down, so no binding can
    // read a partially-destroyed opener while this runs. Then destroy deepest
    // first: an inner opener's menu entry is owned by its parent's children
    // model, so destroying a parent first would invalidate an entry a still-
    // live child opener references.
    var openers = submenuStack
    submenuStack = []
    for (var i = openers.length - 1; i >= 0; i--) openers[i].opener.destroy()
  }

  function enterSubmenu(entry, title) {
    var opener = submenuOpenerComponent.createObject(root, { menu: entry })
    if (!opener) return
    var stack = submenuStack.slice()
    stack.push({ opener: opener, title: title })
    submenuStack = stack
    settleMenuLevel()
  }

  function leaveSubmenu() {
    if (submenuStack.length === 0) return
    var stack = submenuStack.slice()
    var top = stack.pop()
    submenuStack = stack
    top.opener.destroy()
    settleMenuLevel()
  }

  function close() {
    trayMenuOpen = false
    steamPopupOpen = false
  }

  // Compat tools and runtimes show up as installed "apps" alongside real
  // games in appmanifest_*.acf; there's no manifest flag distinguishing them,
  // so filter by Valve's own naming convention for these.
  function looksLikeSteamTool(name) {
    return /^(proton\b|steam linux runtime|steamvr|steamworks common redistributables)/i.test(String(name || "").trim())
  }

  function openSteamLauncher(anchorItem) {
    resetTrayMenu()
    trayMenuOpen = false
    steamPopupAnchor = anchorItem
    steamPopupOpen = true
    steamActiveTab = "installed"
    // Bootstrap only: the background timer (steamChangeCheckTimer) plus its
    // cheap mtime-based change detection keeps this fresh without a rescan
    // tied to the act of opening -- this just covers the very first open of
    // the session, before that timer has had a chance to run yet.
    if (!steamGamesLoaded && !steamGamesLoading) loadSteamGames()
  }

  function loadSteamGames() {
    steamGamesLoading = true
    steamListProc.command = ["bash", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/list-installed-games.sh"]
    steamListProc.running = true
  }

  function onSteamGamesListed(raw) {
    var lines = String(raw || "").split("\n")
    var games = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 2) continue
      var appid = parts[0].trim()
      var name = parts[1].trim()
      var stateFlags = parts.length > 2 ? parseInt(parts[2], 10) : 0
      if (isNaN(stateFlags)) stateFlags = 0
      var sizeOnDisk = parts.length > 3 ? parseInt(parts[3], 10) : 0
      if (isNaN(sizeOnDisk)) sizeOnDisk = 0
      if (!appid || !name || looksLikeSteamTool(name)) continue
      games.push({
        appid: appid,
        name: name,
        stateFlags: stateFlags,
        sizeOnDisk: sizeOnDisk,
        lastPlayed: 0,
        playtimeMinutes: 0,
        description: "",
        descriptionLoaded: false,
        achievementsUnlocked: 0,
        achievementsTotal: 0,
        achievementsLoaded: false,
        // Fallback for a game with no local achievement stat cache at all
        // (never launched/viewed in Steam -- achievementsLoaded stays
        // false forever for those from local data alone). Steam's store
        // page's own category list is a free, already-fetched signal for
        // "does this game have achievements at all" -- confirmed both
        // directions: CloverPit's appdetails response includes category id
        // 22 ("Steam Achievements"), Lone Survivor's doesn't, and Lone
        // Survivor genuinely has none. Sets the same "No achievements" row
        // the local-data path shows, without claiming a bar/count we don't
        // actually know.
        achievementsStoreNone: false,
        tags: [],
        boxArt: "https://cdn.akamai.steamstatic.com/steam/apps/" + appid + "/library_600x900.jpg",
        boxArtFallback: "https://cdn.akamai.steamstatic.com/steam/apps/" + appid + "/header.jpg"
      })
    }
    // Hold these back until last-played times are merged in, so the list
    // never flashes in install order and re-sorts a moment later.
    root.steamGamesPending = games
    steamLastPlayedProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/steam-last-played.py"]
    steamLastPlayedProc.running = true
  }

  // Steam's own AppRunning/updating bits (well-established community-
  // documented values -- this machine's idle baseline of "4" == just
  // FullyInstalled, nothing else set, matches expectations). Read fresh
  // every rescan, so no separate polling loop is needed for either state.
  readonly property int steamStateFlagRunning: 64
  readonly property int steamStateFlagsUpdating: 256 | 1024 | 131072 | 262144 | 524288

  function isGameRunning(stateFlags) {
    return (Number(stateFlags) & root.steamStateFlagRunning) !== 0
  }

  function isGameUpdating(stateFlags) {
    return (Number(stateFlags) & root.steamStateFlagsUpdating) !== 0
  }

  function playtimeSuffix(minutes) {
    var m = Number(minutes) || 0
    if (m < 30) return ""
    var hrs = m / 60
    return " · " + (hrs < 10 ? hrs.toFixed(1) : Math.round(hrs)) + " hrs"
  }

  // Matches the convention already used elsewhere in the Omarchy shell
  // (network panel's Model.js formatBytes) rather than inventing a new one.
  function formatBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
    return (n / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  function switchSteamTab(tab) {
    steamActiveTab = tab
    if (tab === "notinstalled") loadSteamNotInstalled()
  }

  function loadSteamNotInstalled() {
    if (steamNotInstalledLoaded || steamNotInstalledLoading) return

    var cache = root.steamNotInstalledCache
    var ageSec = (cache && typeof cache.generatedAt === "number")
      ? Math.floor(Date.now() / 1000) - cache.generatedAt : -1
    // Array, not an appid-keyed object: Steam appids are all-numeric
    // strings, and JS objects always enumerate integer-like keys in
    // ascending numeric order regardless of insertion order -- an earlier
    // object-keyed cache format silently reordered this list to plain
    // appid order on every cache-hit reload instead of preserving whatever
    // order the original scan produced. An old on-disk cache in that
    // shape just reads as stale here (Array.isArray fails) and triggers
    // one fresh full scan, which writes it back in the new shape.
    if (ageSec >= 0 && ageSec < root.steamNotInstalledCacheMaxAgeSec && Array.isArray(cache.games)) {
      var games = cache.games.map(function(g) {
        return {
          appid: g.appid,
          name: g.name,
          stateFlags: 0,
          lastPlayed: g.lastPlayed || 0,
          playtimeMinutes: g.playtimeMinutes || 0,
          description: "",
          descriptionLoaded: false,
          achievementsUnlocked: g.achievementsUnlocked || 0,
          achievementsTotal: g.achievementsTotal || 0,
          achievementsLoaded: !!g.achievementsLoaded,
          achievementsStoreNone: false,
          tags: [],
          boxArt: "https://cdn.akamai.steamstatic.com/steam/apps/" + g.appid + "/library_600x900.jpg",
          boxArtFallback: "https://cdn.akamai.steamstatic.com/steam/apps/" + g.appid + "/header.jpg"
        }
      })
      root.primeNotInstalledDescriptions(games)
      root.steamNotInstalled = games
      root.steamNotInstalledLoaded = true
      return
    }

    steamNotInstalledLoading = true
    steamNotInstalledProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/steam-not-installed.py"]
    steamNotInstalledProc.running = true
  }

  function cacheSteamNotInstalled(games) {
    var list = games.map(function(g) {
      return {
        appid: g.appid,
        name: g.name,
        lastPlayed: g.lastPlayed,
        playtimeMinutes: g.playtimeMinutes,
        achievementsUnlocked: g.achievementsUnlocked,
        achievementsTotal: g.achievementsTotal,
        achievementsLoaded: g.achievementsLoaded
      }
    })
    var cache = { generatedAt: Math.floor(Date.now() / 1000), games: list }
    root.steamNotInstalledCache = cache
    notInstalledCacheFile.setText(JSON.stringify(cache))
  }

  function onNotInstalledCacheLoaded(raw) {
    try {
      var parsed = JSON.parse(raw)
      root.steamNotInstalledCache = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : {}
    } catch (e) {
      root.steamNotInstalledCache = {}
    }
  }

  function onSteamNotInstalledListed(raw) {
    var lines = String(raw || "").split("\n")
    var games = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var tab = line.indexOf("\t")
      if (tab === -1) continue
      var appid = line.slice(0, tab).trim()
      var name = line.slice(tab + 1).trim()
      if (!appid || !name) continue
      // Same shape as an installed game's object (minus disk usage, which
      // only means something for something actually on disk) so the shared
      // SteamGameCard component can render either one identically.
      games.push({
        appid: appid,
        name: name,
        stateFlags: 0,
        lastPlayed: 0,
        playtimeMinutes: 0,
        description: "",
        descriptionLoaded: false,
        achievementsUnlocked: 0,
        achievementsTotal: 0,
        achievementsLoaded: false,
        achievementsStoreNone: false,
        tags: [],
        boxArt: "https://cdn.akamai.steamstatic.com/steam/apps/" + appid + "/library_600x900.jpg",
        boxArtFallback: "https://cdn.akamai.steamstatic.com/steam/apps/" + appid + "/header.jpg"
      })
    }
    root.steamNotInstalledPending = games
    // Reuse the same local, free scripts already used for installed games --
    // neither is scoped to installed-only (see their own module docstrings:
    // steam-last-played.py reads localconfig.vdf's apps section, which
    // covers every appid Steam has ever configured, and steam-achievements.py
    // globs the shared appcache/stats dir, which persists regardless of
    // current install state) -- so a game played for 40 hours years ago and
    // since uninstalled still shows its real playtime/achievement history,
    // at zero extra cost. Run again rather than reusing the installed scan's
    // already-parsed maps: this tab can be opened long after that scan ran,
    // and both scripts are cheap, local, sub-second reads.
    steamNotInstalledLastPlayedProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/steam-last-played.py"]
    steamNotInstalledLastPlayedProc.running = true
  }

  function onSteamNotInstalledLastPlayedListed(raw) {
    var lastPlayed = {}
    var playtime = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 2) continue
      var appid = parts[0].trim()
      var epoch = parseInt(parts[1], 10)
      var mins = parts.length > 2 ? parseInt(parts[2], 10) : 0
      if (appid && !isNaN(epoch)) lastPlayed[appid] = epoch
      if (appid && !isNaN(mins)) playtime[appid] = mins
    }

    var games = (root.steamNotInstalledPending || []).map(function(g) {
      var copy = Object.assign({}, g)
      copy.lastPlayed = lastPlayed[g.appid] || 0
      copy.playtimeMinutes = playtime[g.appid] || 0
      return copy
    })
    root.steamNotInstalledPending = null
    root.steamNotInstalled = games
    steamNotInstalledAchievementsProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/steam-achievements.py"]
    steamNotInstalledAchievementsProc.running = true
  }

  function onSteamNotInstalledAchievementsListed(raw) {
    var byAppid = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length !== 3) continue
      var appid = parts[0].trim()
      var unlocked = parseInt(parts[1], 10)
      var total = parseInt(parts[2], 10)
      if (!appid || isNaN(unlocked) || isNaN(total) || total < 0) continue
      byAppid[appid] = { unlocked: unlocked, total: total }
    }

    var games = root.steamNotInstalled.map(function(g) {
      var entry = byAppid[g.appid]
      if (!entry) return g
      var copy = Object.assign({}, g)
      copy.achievementsUnlocked = entry.unlocked
      copy.achievementsTotal = entry.total
      copy.achievementsLoaded = true
      return copy
    })
    root.primeNotInstalledDescriptions(games)
    root.steamNotInstalled = games
    root.steamNotInstalledLoading = false
    root.steamNotInstalledLoaded = true
    root.cacheSteamNotInstalled(games)
  }

  function setSteamNotInstalledField(appid, field, value) {
    var games = root.steamNotInstalled.slice()
    for (var i = 0; i < games.length; i++) {
      if (games[i].appid !== appid) continue
      var updated = Object.assign({}, games[i])
      updated[field] = value
      games[i] = updated
      break
    }
    root.steamNotInstalled = games
  }

  // Applies any fresh cached description/tags/achievement-fallback data
  // directly onto each game object in place (mutating the plain objects in
  // `games` before it's ever assigned to the reactive `steamNotInstalled`
  // property) and queues a real fetch only for whatever's left -- called
  // once per bulk load of the whole list, not once per game.
  //
  // The previous approach routed every game through setSteamNotInstalledField
  // (up to 4 calls each for a cache hit), which does a full array copy AND
  // reassigns the whole `steamNotInstalled` property every single call. With
  // a few-hundred-game library and most descriptions already cached from an
  // earlier session, that meant thousands of full-array-copy reassignments
  // in one synchronous burst -- confirmed as the cause of a ~20s UI freeze
  // when switching to this tab: a ListView bound to a plain JS array treats
  // every reassignment of that array as an entirely new model and
  // re-realizes every visible delegate (box art included) from scratch each
  // time, not just once at the end.
  function primeNotInstalledDescriptions(games) {
    var nowSec = Math.floor(Date.now() / 1000)
    var needsFetch = []
    for (var i = 0; i < games.length; i++) {
      var g = games[i]
      var cached = root.descriptionCache[g.appid]
      if (cached && typeof cached.fetchedAt === "number") {
        var ageSec = nowSec - cached.fetchedAt
        if (ageSec >= 0 && ageSec < root.descriptionCacheMaxAgeSec) {
          g.description = cached.description || ""
          g.achievementsStoreNone = !!cached.noAchievements
          g.tags = Array.isArray(cached.tags) ? cached.tags : []
          g.descriptionLoaded = true
          continue
        }
      }
      needsFetch.push(g.appid)
    }
    if (needsFetch.length > 0) {
      root.steamNotInstalledFetchQueue = root.steamNotInstalledFetchQueue.concat(needsFetch)
      root.drainSteamNotInstalledFetchQueue()
    }
  }

  function drainSteamNotInstalledFetchQueue() {
    // Under correct operation this loop body runs at most
    // steamNotInstalledFetchConcurrency times per call (inFlight rises by 1
    // each iteration until it hits the cap) -- this hard stop is a
    // defensive backstop, not the expected path, in case inFlight and the
    // queue ever desync (confirmed elsewhere this session: a *different*
    // bug -- writing a cache file inside the watched plugin directory --
    // caused a full widget reload-and-reset storm that looked like this
    // loop running away; that root cause is fixed separately, but a hard
    // cap here costs nothing and prevents any future desync from ever
    // being able to spin unbounded again).
    var guard = 0
    while (root.steamNotInstalledFetchInFlight < root.steamNotInstalledFetchConcurrency
      && root.steamNotInstalledFetchQueue.length > 0) {
      if (++guard > root.steamNotInstalledFetchConcurrency * 2) {
        console.warn("drainSteamNotInstalledFetchQueue: stopped after " + guard + " iterations in one call -- inFlight/queue may be desynced (inFlight=" + root.steamNotInstalledFetchInFlight + " queueLen=" + root.steamNotInstalledFetchQueue.length + ")")
        break
      }
      var appid = root.steamNotInstalledFetchQueue.shift()
      root.steamNotInstalledFetchInFlight++
      var fetcher = steamDescriptionFetcher.createObject(root, { appid: appid, forNotInstalled: true })
      fetcher.start()
    }
  }

  // Doesn't close the popup, unlike launchSteamApp -- browsing and kicking
  // off installs for a few owned-but-uninstalled games in one sitting is a
  // reasonable thing to want to do, and each one is a fire-and-forget
  // request to Steam (it handles the actual download in its own UI).
  function installSteamApp(appid) {
    Util.execArgv(["xdg-open", "steam://install/" + appid])
  }

  function onSteamLastPlayedListed(raw) {
    var lastPlayed = {}
    var playtime = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 2) continue
      var appid = parts[0].trim()
      var epoch = parseInt(parts[1], 10)
      var mins = parts.length > 2 ? parseInt(parts[2], 10) : 0
      if (appid && !isNaN(epoch)) lastPlayed[appid] = epoch
      if (appid && !isNaN(mins)) playtime[appid] = mins
    }

    var games = (root.steamGamesPending || []).map(function(g) {
      var copy = Object.assign({}, g)
      copy.lastPlayed = lastPlayed[g.appid] || 0
      copy.playtimeMinutes = playtime[g.appid] || 0
      return copy
    })
    // Currently-running games float to the top regardless of last-played;
    // otherwise most recently played first, never-played (0) sinking to the
    // bottom, alphabetical among ties.
    games.sort(function(a, b) {
      var aRunning = root.isGameRunning(a.stateFlags)
      var bRunning = root.isGameRunning(b.stateFlags)
      if (aRunning !== bRunning) return aRunning ? -1 : 1
      if (b.lastPlayed !== a.lastPlayed) return b.lastPlayed - a.lastPlayed
      return a.name.localeCompare(b.name)
    })

    root.steamGamesPending = null
    root.steamGames = games
    root.steamGamesLoading = false
    root.steamGamesLoaded = true
    root.steamLastFullScanAt = Date.now()
    for (var g = 0; g < games.length; g++) fetchSteamDescription(games[g].appid)
    loadSteamAchievements()
  }

  function loadSteamAchievements() {
    steamAchievementsProc.command = ["python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/scripts/steam-achievements.py"]
    steamAchievementsProc.running = true
  }

  // One combined local read (Steam's own binary achievement-stat cache, no
  // network) rather than one process per game -- unlike descriptions, this
  // has no reason to be cached across popup opens: it's already as cheap as
  // the games-list/last-played rescans that already happen on every open.
  // Games with no line in the output at all (no local stats file yet --
  // Steam hasn't fetched them) are left with achievementsLoaded=false,
  // which the popup reads as "no achievement row at all -- unknown". A
  // game the script *did* report with total=0 (confirmed no achievements)
  // still gets achievementsLoaded=true, distinguishing "known: none" from
  // "unknown" -- the popup shows "No achievements" for the former.
  function onSteamAchievementsListed(raw) {
    // One reassignment of root.steamGames for the whole batch, not one per
    // field per game via setSteamGameField -- steamGames is a plain JS
    // array, so each reassignment recreates every Repeater delegate (all
    // box art Images included). Looping setSteamGameField 3x per game here
    // caused dozens of full re-renders in a row, visible as the same box
    // art URL being re-fetched over and over in the log.
    var byAppid = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length !== 3) continue
      var appid = parts[0].trim()
      var unlocked = parseInt(parts[1], 10)
      var total = parseInt(parts[2], 10)
      if (!appid || isNaN(unlocked) || isNaN(total) || total < 0) continue
      byAppid[appid] = { unlocked: unlocked, total: total }
    }
    if (Object.keys(byAppid).length === 0) return

    var games = root.steamGames.map(function(g) {
      var entry = byAppid[g.appid]
      if (!entry) return g
      var copy = Object.assign({}, g)
      copy.achievementsUnlocked = entry.unlocked
      copy.achievementsTotal = entry.total
      copy.achievementsLoaded = true
      return copy
    })
    root.steamGames = games
  }

  function relativeLastPlayed(epoch) {
    if (!epoch) return "Never played"
    var deltaSec = Math.max(0, Math.floor(Date.now() / 1000) - epoch)
    var day = 86400
    if (deltaSec < day) return "Played today"
    var days = Math.floor(deltaSec / day)
    if (days === 1) return "Played yesterday"
    if (days < 7) return "Played " + days + " days ago"
    if (days < 30) {
      var weeks = Math.floor(days / 7)
      return "Played " + weeks + (weeks === 1 ? " week ago" : " weeks ago")
    }
    if (days < 365) {
      var months = Math.floor(days / 30)
      return "Played " + months + (months === 1 ? " month ago" : " months ago")
    }
    var years = Math.floor(days / 365)
    return "Played " + years + (years === 1 ? " year ago" : " years ago")
  }

  function setSteamGameField(appid, field, value) {
    var games = root.steamGames.slice()
    for (var i = 0; i < games.length; i++) {
      if (games[i].appid !== appid) continue
      var updated = Object.assign({}, games[i])
      updated[field] = value
      games[i] = updated
      break
    }
    root.steamGames = games
  }

  function fetchSteamDescription(appid) {
    var cached = root.descriptionCache[appid]
    if (cached && typeof cached.fetchedAt === "number") {
      var ageSec = Math.floor(Date.now() / 1000) - cached.fetchedAt
      if (ageSec >= 0 && ageSec < root.descriptionCacheMaxAgeSec) {
        root.setSteamGameField(appid, "description", cached.description || "")
        root.setSteamGameField(appid, "achievementsStoreNone", !!cached.noAchievements)
        root.setSteamGameField(appid, "tags", Array.isArray(cached.tags) ? cached.tags : [])
        root.setSteamGameField(appid, "descriptionLoaded", true)
        return
      }
    }
    var fetcher = steamDescriptionFetcher.createObject(root, { appid: appid })
    fetcher.start()
  }

  function cacheSteamDescription(appid, description, noAchievements, tags) {
    var cache = Object.assign({}, root.descriptionCache)
    cache[appid] = { description: description, noAchievements: !!noAchievements, tags: tags || [], fetchedAt: Math.floor(Date.now() / 1000) }
    root.descriptionCache = cache
    descriptionCacheFile.setText(JSON.stringify(cache))
  }

  function onDescriptionCacheLoaded(raw) {
    try {
      var parsed = JSON.parse(raw)
      root.descriptionCache = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : {}
    } catch (e) {
      root.descriptionCache = {}
    }
  }

  function launchSteamApp(appid) {
    Util.execArgv(["xdg-open", "steam://rungameid/" + appid])
    steamPopupOpen = false
  }

  function openSteamUri(uri) {
    Util.execArgv(["xdg-open", uri])
    steamPopupOpen = false
  }

  function openTrayMenu(item, anchorItem, mouse) {
    if (!item) return
    if (!item.menu) {
      var point = anchorItem.QsWindow.contentItem.mapFromItem(anchorItem, mouse.x, mouse.y)
      item.display(anchorItem.QsWindow.window, point.x, point.y)
      return
    }

    // Reset before switching items: trayMenuOpener.menu binds to
    // activeTrayItem.menu, so assigning a new item invalidates the old root's
    // children immediately, before any nested opener referencing them would
    // otherwise get torn down.
    resetTrayMenu()
    steamPopupOpen = false
    activeTrayItem = item
    activeTrayAnchor = anchorItem
    trayMenuOpen = true
  }

  function trayIconSource(icon) {
    // Quickshell already resolves the tray icon into a ready-to-use image://
    // URL, including a "?path=" fallback search dir for apps that ship their
    // tray icon outside a standard theme (e.g. Steam's flat public/ dir).
    //
    // Except: for Steam specifically, image://icon/steam_tray_mono?path=...
    // does not actually render steam_tray_mono.png -- confirmed via
    // screenshot, it silently resolves to Steam's unrelated full-color app
    // icon instead (a Quickshell/theme-fallback quirk, not fixable from
    // here). The "?path=" hint already tells us exactly where the real file
    // is, so read it directly instead of trusting the icon:// lookup.
    var raw = String(icon || "")
    var qsAt = raw.indexOf("?path=")
    if (qsAt !== -1) {
      var dir = decodeURIComponent(raw.slice(qsAt + 6))
      var nameStart = raw.lastIndexOf("/", qsAt) + 1
      var name = raw.slice(nameStart, qsAt)
      if (name && dir) return Util.fileUrl(dir + "/" + name + ".png")
    }
    return raw
  }

  // Symbolic icons ship a fixed fill (often near-white) that the host is meant
  // to recolor to its foreground; detect them by the freedesktop "-symbolic"
  // name suffix so they can be tinted instead of rendered as-is. Steam ships
  // its tray glyph as "steam_tray_mono" -- a near-transparent pale-gray PNG
  // under the same "host tints this" convention, just with Valve's own
  // "_mono" suffix instead -- so without this it renders raw and washed-out.
  function iconIsSymbolic(icon) {
    var name = String(icon || "").split("?")[0]
    return name.slice(-9) === "-symbolic" || name.slice(-5) === "_mono"
  }

  // ~/.cache, NOT anywhere under the plugin's own ~/.config/omarchy/plugins/
  // directory -- root-caused a severe bug: quickshell watches a plugin's
  // own directory for hot-reload, and writing this file *inside* it (as an
  // earlier version of this plugin did) tripped that watcher on every
  // write. With the not-installed tab's few-hundred description fetches
  // each writing this file individually, that produced a self-sustaining
  // storm: write -> "plugin changed, reloading" -> full widget teardown
  // and reinit -> reset state re-triggers the whole not-installed fetch
  // pipeline from scratch -> writes again -> reloads again, forever,
  // consuming memory and CPU without bound each cycle. Confirmed live on
  // this machine: quickshell hit 9.8GB RSS and had to be force-killed
  // twice before this was found and fixed.
  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omarchy-steam-launcher"

  FileView {
    id: descriptionCacheFile
    path: root.cacheDir + "/steam-descriptions.json"
    atomicWrites: true
    printErrors: false
    onLoaded: root.onDescriptionCacheLoaded(text())
    onLoadFailed: root.onDescriptionCacheLoaded("{}")
  }

  FileView {
    id: notInstalledCacheFile
    path: root.cacheDir + "/not-installed.json"
    atomicWrites: true
    printErrors: false
    onLoaded: root.onNotInstalledCacheLoaded(text())
    onLoadFailed: root.onNotInstalledCacheLoaded("{}")
  }

  Process {
    id: steamListProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamGamesListed(text)
    }
  }

  Process {
    id: steamLastPlayedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamLastPlayedListed(text)
    }
  }

  Process {
    id: steamAchievementsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamAchievementsListed(text)
    }
  }

  Process {
    id: steamNotInstalledProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamNotInstalledListed(text)
    }
  }

  // Separate Process instances from the installed-list's own
  // steamLastPlayedProc/steamAchievementsProc, even though they run the
  // exact same scripts -- this tab can load while the background timer's
  // installed-list rescan is also in flight, and sharing one Process
  // between two independent callers would race.
  Process {
    id: steamNotInstalledLastPlayedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamNotInstalledLastPlayedListed(text)
    }
  }

  Process {
    id: steamNotInstalledAchievementsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSteamNotInstalledAchievementsListed(text)
    }
  }

  // One short-lived curl process per game, fetching Steam's free/keyless
  // appdetails endpoint for a short blurb. Box art comes straight from the
  // CDN via Image.source instead (no API round trip needed for that part).
  Component {
    id: steamDescriptionFetcher

    Process {
      id: fetchProc
      required property string appid
      // Installed games (a naturally small list) fire immediately, one
      // process per game, same as always. Not-installed games go through
      // primeNotInstalledDescriptions/drainSteamNotInstalledFetchQueue's
      // concurrency-limited queue instead -- this flag is just which set of
      // setters/bookkeeping to use on completion, the curl call itself is
      // identical either way.
      property bool forNotInstalled: false

      function start() {
        // "categories"/"genres" alongside "basic" cost nothing extra (one
        // request, already being made for the description). categories
        // recovers a fallback signal for whether a game has achievements at
        // all, for a game with zero local achievement-stat cache (never
        // launched/viewed in Steam, so scripts/steam-achievements.py has
        // nothing to report) -- category id 22 is Valve's own "Steam
        // Achievements" store tag. genres gives up to 5 tags to show under
        // the description (e.g. "Action, Indie, Strategy").
        // --max-filesize caps the response at the curl level (independent of
        // any Content-Length header) before it's buffered whole into QML
        // memory by StdioCollector below -- a real appdetails response is a
        // few KB, so 2 MiB leaves generous headroom while still bounding
        // what a compromised/misbehaving endpoint could hand back.
        command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", "2097152",
          "https://store.steampowered.com/api/appdetails?appids=" + appid + "&filters=basic,categories,genres&l=english"]
        running = true
      }

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          try {
            var parsed = JSON.parse(text)
            var entry = parsed[fetchProc.appid]
            // Only cache a genuine answer from Steam. A network hiccup (curl
            // failing, empty stdout) throws here instead, which deliberately
            // leaves nothing cached so it retries next launch rather than
            // locking in a blank description for a month.
            if (entry && entry.success) {
              var desc = entry.data ? String(entry.data.short_description || "") : ""
              var categories = (entry.data && Array.isArray(entry.data.categories)) ? entry.data.categories : []
              var hasAchievementsTag = categories.some(function(c) { return c && c.id === 22 })
              var noAchievements = !hasAchievementsTag
              var genres = (entry.data && Array.isArray(entry.data.genres)) ? entry.data.genres : []
              var tags = genres.map(function(g) { return String(g && g.description || "") }).filter(function(t) { return t !== "" }).slice(0, 5)
              var setField = fetchProc.forNotInstalled ? root.setSteamNotInstalledField : root.setSteamGameField
              setField(fetchProc.appid, "description", desc)
              setField(fetchProc.appid, "achievementsStoreNone", noAchievements)
              setField(fetchProc.appid, "tags", tags)
              root.cacheSteamDescription(fetchProc.appid, desc, noAchievements, tags)
            }
          } catch (e) {
            // Leave description blank this run; the card still shows name + art.
          }
          var setLoaded = fetchProc.forNotInstalled ? root.setSteamNotInstalledField : root.setSteamGameField
          setLoaded(fetchProc.appid, "descriptionLoaded", true)
          if (fetchProc.forNotInstalled) {
            root.steamNotInstalledFetchInFlight--
            root.drainSteamNotInstalledFetchQueue()
          }
          fetchProc.destroy()
        }
      }
    }
  }

  QsMenuOpener {
    id: trayMenuOpener
    menu: root.activeTrayItem ? root.activeTrayItem.menu : null
  }

  PopupCard {
    id: trayMenuPopup
    anchorItem: root.activeTrayAnchor || root
    owner: root
    bar: root.bar
    open: root.trayMenuOpen
    // The card fades out over 140ms (visible stays true for that whole time --
    // see PopupCard's own visible: open || card.opacity > 0), so resetting on
    // "open" would swap a live submenu for the root menu mid-fade: a visible
    // flash, and a resize/reposition if the two have different geometry. Wait
    // for the fade to actually finish. Switching to a different tray item
    // still resets immediately, from openTrayMenu() itself.
    onVisibleChanged: if (!visible) root.resetTrayMenu()
    padding: Style.space(8)
    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    contentWidth: trayMenuPopup.fittedContentWidth(Style.space(232))
    contentHeight: trayMenuPopup.fittedContentHeight(menuHeaderHeight + trayMenuColumn.implicitHeight, Style.space(420))

    // Column skips invisible children but keeps reporting their height, so
    // read the header's extent through its own visibility.
    readonly property int menuHeaderHeight: menuHeader.visible ? menuHeader.implicitHeight : 0

    Column {
      id: trayMenuLayout
      anchors.fill: parent
      spacing: 0

      // Header for a drilled-into submenu: names where we are and walks back
      // out. Pinned above the Flickable rather than scrolling with the rows,
      // so the way back stays reachable in a submenu taller than the card.
      // Only present below the root level, so the root menu is unchanged.
      Column {
        id: menuHeader
        visible: root.submenuDepth > 0
        width: trayMenuLayout.width
        spacing: 0

        Item {
          id: menuBackRow
          width: menuHeader.width
          implicitHeight: Style.space(30)

          Rectangle {
            anchors.fill: parent
            radius: Math.max(2, Style.cornerRadius)
            color: backMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            width: Style.space(22)
            horizontalAlignment: Text.AlignHCenter
            text: "‹"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(28)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            text: root.currentTitle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.menuLevelSettling) return
              // Reset before the model swap so the parent level shows from
              // the top (same ordering as the row delegate below).
              trayMenuFlick.contentY = 0
              root.leaveSubmenu()
            }
          }
        }

        Item {
          width: menuHeader.width
          implicitHeight: Style.space(11)

          Rectangle {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: Color.popups.border
            opacity: 0.45
          }
        }
      }

      Flickable {
        id: trayMenuFlick
        width: trayMenuLayout.width
        height: trayMenuLayout.height - trayMenuPopup.menuHeaderHeight
        contentWidth: width
        contentHeight: trayMenuColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: trayMenuColumn
          width: trayMenuFlick.width
          spacing: 0

          Repeater {
            model: root.currentChildren

            delegate: Item {
              id: menuRow
              required property var modelData
              required property int index

              readonly property string rowText: String(modelData.text || "")
              readonly property string activeTitle: root.activeTrayItem ? String(root.activeTrayItem.title || root.activeTrayItem.id || "") : ""
              // Both only ever describe the root menu; inside a submenu the first
              // rows are real entries and must not be swallowed.
              readonly property bool atRoot: root.submenuDepth === 0
              readonly property bool rootTitleEntry: atRoot && index === 0 && modelData.hasChildren && rowText.toLowerCase() === activeTitle.toLowerCase()
              readonly property bool leadingSeparator: atRoot && modelData.isSeparator && index <= 1
              readonly property bool hiddenRow: rootTitleEntry || leadingSeparator

              visible: !hiddenRow
              width: trayMenuColumn.width
              implicitHeight: hiddenRow ? 0 : (modelData.isSeparator ? Style.space(11) : Style.space(30))
              opacity: modelData.enabled ? 1.0 : 0.45

              Rectangle {
                visible: menuRow.modelData.isSeparator
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                color: Color.popups.border
                opacity: 0.45
              }

              Rectangle {
                visible: !menuRow.modelData.isSeparator
                anchors.fill: parent
                radius: Math.max(2, Style.cornerRadius)
                color: rowMouse.containsMouse && menuRow.modelData.enabled ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
              }

              Text {
                textFormat: Text.PlainText
                visible: !menuRow.modelData.isSeparator && menuRow.modelData.buttonType !== QsMenuButtonType.None
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                text: menuRow.modelData.checkState === Qt.Checked ? "" : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Image {
                id: menuIcon
                visible: !menuRow.modelData.isSeparator && String(menuRow.modelData.icon || "") !== ""
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(24)
                width: Style.space(16)
                height: Style.space(16)
                fillMode: Image.PreserveAspectFit
                // Decode at physical pixels: IconImage uses the logical size,
                // which leaves PNG icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: menuRow.modelData.icon
              }

              Text {
                textFormat: Text.PlainText
                visible: !menuRow.modelData.isSeparator
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: menuIcon.visible ? Style.space(46) : Style.space(28)
                anchors.right: submenuGlyph.left
                anchors.rightMargin: Style.space(8)
                text: menuRow.rowText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: submenuGlyph
                visible: !menuRow.modelData.isSeparator && menuRow.modelData.hasChildren
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                text: "›"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !menuRow.modelData.isSeparator && menuRow.modelData.enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (root.menuLevelSettling) return
                  if (menuRow.modelData.hasChildren) {
                    // Reset scroll BEFORE swapping the model: the swap destroys
                    // this delegate synchronously and ids stop resolving after.
                    trayMenuFlick.contentY = 0
                    root.enterSubmenu(menuRow.modelData, menuRow.rowText)
                  } else {
                    menuRow.modelData.triggered()
                    root.close()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // KeyboardPanel, not PopupCard: PopupCard is built on PopupWindow (an
  // xdg-popup) which only gets real Wayland keyboard focus routed to it in
  // limited cases -- buttons work fine (mouse clicks don't need keyboard
  // focus), but a TextField inside one silently accepts no typed input at
  // all, confirmed the hard way building the Cameras plugin. KeyboardPanel
  // explicitly manages WlrLayershell.keyboardFocus and has the same API
  // (anchorItem/bar/owner/open/contentWidth/Height/fittedContentWidth/Height
  // all match) -- a drop-in swap plus a focusTarget.
  KeyboardPanel {
    id: steamLauncherPopup
    anchorItem: root.steamPopupAnchor || root
    owner: root
    bar: root.bar
    open: root.steamPopupOpen
    focusTarget: steamSearchField
    padding: Style.space(10)
    borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45), Math.max(1, Style.space(2)))
    contentWidth: steamLauncherPopup.fittedContentWidth(Style.space(560))
    // Capped to exactly steamVisibleRows game rows tall (plus the fixed
    // header above them): computed from the header items' own
    // implicitHeight and the row/spacing constants the delegate below
    // already uses, rather than a flat magic pixel number, so this stays
    // correct if those constants ever change.
    // Each card is now 3 sub-rows (name+status / art+description /
    // achievement bar) instead of 2 -- games without achievement data just
    // leave that sub-row's space empty rather than shrinking the row
    // per-item (a uniform row height keeps the "N visible rows" math simple
    // and correct without per-row variable sizing).
    readonly property int steamRowHeight: Style.space(140)
    // Both tabs use the same SteamGameCard row height now that not-installed
    // entries render with full detail too (box art/description/tags/
    // achievements), so a single cap covers either tab.
    readonly property int steamVisibleRows: 5
    readonly property int steamHeaderHeight: steamHeaderRow.implicitHeight + steamLauncherColumn.spacing
      + steamTabsRow.implicitHeight + steamLauncherColumn.spacing + steamSearchField.implicitHeight
    readonly property int steamListCapHeight: steamHeaderHeight + steamLauncherColumn.spacing
      + steamVisibleRows * steamRowHeight + (steamVisibleRows - 1) * steamLauncherColumn.spacing
    contentHeight: steamLauncherPopup.fittedContentHeight(steamLauncherColumn.implicitHeight, steamListCapHeight)

    // A library beyond a handful of games would otherwise just grow the
    // popup unbounded (or silently clip past the height cap above), so this
    // scrolls instead once contentHeight outgrows the capped viewport.
    Flickable {
      id: steamLauncherFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: steamLauncherColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: steamLauncherColumn
        width: steamLauncherFlick.width
        spacing: Style.space(10)

        Item {
          id: steamHeaderRow
          width: parent.width
          implicitHeight: Math.max(steamTitleIcon.height, steamTitleText.implicitHeight, steamButtonsRow.implicitHeight)

          // Same TrayIcon used for the bar icon itself, so the title picks
          // up the exact same live-icon/fallback-file/emoji logic for free
          // (Steam's real icon while running, the same file read directly
          // while closed, the 🎮 placeholder when Steam isn't installed).
          TrayIcon {
            id: steamTitleIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.body
            height: Style.font.body
            icon: root.steamItem ? root.steamItem.icon : null
            fallbackFile: (!root.steamItem && root.steamInstalled)
              ? (Quickshell.env("HOME") + "/.local/share/Steam/public/steam_tray_mono.png") : ""
          }

          Text {
            id: steamTitleText
            anchors.left: steamTitleIcon.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "Steam Launcher"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Row {
            id: steamButtonsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              iconText: ""
              text: "Library"
              foreground: root.foreground
              horizontalPadding: 8
              verticalPadding: 3
              iconSize: Style.font.bodySmall
              fontSize: Style.font.bodySmall
              onClicked: root.openSteamUri("steam://open/games")
            }

            Button {
              iconText: ""
              text: "Big Picture"
              foreground: root.foreground
              horizontalPadding: 8
              verticalPadding: 3
              iconSize: Style.font.bodySmall
              fontSize: Style.font.bodySmall
              onClicked: root.openSteamUri("steam://open/bigpicture")
            }

            Button {
              iconText: ""
              text: "VR"
              foreground: root.foreground
              horizontalPadding: 8
              verticalPadding: 3
              iconSize: Style.font.bodySmall
              fontSize: Style.font.bodySmall
              onClicked: root.openSteamUri("steam://open/vr")
            }
          }
        }

        Item {
          id: steamTabsRow
          width: parent.width
          implicitHeight: Math.max(installedTab.height, notInstalledTab.height, steamDiskUsageText.implicitHeight)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)

            // Shows the filtered count while a search is active -- the total
            // count would be misleading sitting above a shorter list.
            Item {
              id: installedTab
              width: installedTabText.implicitWidth
              height: installedTabText.implicitHeight + Style.space(5)

              Text {
                id: installedTabText
                anchors.left: parent.left
                anchors.top: parent.top
                text: "Installed games (" + root.filteredSteamGames.length + ")"
                color: root.steamActiveTab === "installed" ? root.foreground : Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.steamActiveTab === "installed"
              }

              Rectangle {
                visible: root.steamActiveTab === "installed"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(1, Style.space(2))
                radius: height / 2
                color: root.foreground
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchSteamTab("installed")
              }
            }

            // Count stays blank until the section has actually been loaded
            // once (lazy -- see steamNotInstalled's own property comment).
            Item {
              id: notInstalledTab
              width: notInstalledTabText.implicitWidth
              height: notInstalledTabText.implicitHeight + Style.space(5)

              Text {
                id: notInstalledTabText
                anchors.left: parent.left
                anchors.top: parent.top
                text: "Not installed" + (root.steamNotInstalledLoaded ? " (" + root.filteredSteamNotInstalled.length + ")" : "")
                color: root.steamActiveTab === "notinstalled" ? root.foreground : Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.steamActiveTab === "notinstalled"
              }

              Rectangle {
                visible: root.steamActiveTab === "notinstalled"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(1, Style.space(2))
                radius: height / 2
                color: root.foreground
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchSteamTab("notinstalled")
              }
            }
          }

          // Disk usage only means something for installed games -- see
          // totalDiskBytes's own comment on why it ignores the search filter.
          Text {
            id: steamDiskUsageText
            visible: root.steamActiveTab === "installed" && root.steamGames.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatBytes(root.totalDiskBytes) + " total"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        TextField {
          id: steamSearchField
          width: parent.width
          verticalPadding: 4
          placeholderText: root.steamActiveTab === "installed" ? "Search games…" : "Search owned games…"
          foreground: root.foreground
          font.family: root.fontFamily
          text: root.steamSearchQuery
          onTextChanged: root.steamSearchQuery = text
        }

        Text {
          visible: root.steamActiveTab === "installed" && root.steamGamesLoading && root.steamGames.length === 0
          text: "Loading library…"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Text {
          visible: root.steamActiveTab === "installed" && root.steamGamesLoaded && root.steamGames.length === 0
          text: root.steamInstalled ? "No installed games found." : "Steam is not installed on this machine."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Text {
          textFormat: Text.PlainText
          visible: root.steamActiveTab === "installed" && root.steamGamesLoaded && root.steamGames.length > 0
            && root.filteredSteamGames.length === 0 && root.steamSearchQuery.trim() !== ""
          text: "No games match \"" + root.steamSearchQuery.trim() + "\"."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Repeater {
          // Zero delegates while the other tab is active, not just hidden
          // ones -- same reasoning as the not-installed Repeater below.
          model: root.steamActiveTab === "installed" ? root.filteredSteamGames : []

          delegate: SteamGameCard {
            required property var modelData
            game: modelData
            actionTooltip: "Launch"
            hoverGlyph: "▶"
            onActivated: root.launchSteamApp(modelData.appid)
          }
        }

        // Owned-but-not-installed games -- the tab above triggers the load
        // (see steamNotInstalled's own property comment for why this isn't
        // just rescanned eagerly like the installed list).
        Text {
          visible: root.steamActiveTab === "notinstalled" && root.steamNotInstalledLoading
          text: "Loading owned games…"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Text {
          visible: root.steamActiveTab === "notinstalled" && root.steamNotInstalledLoaded && root.steamNotInstalled.length === 0
          text: "Everything you own is already installed."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Text {
          textFormat: Text.PlainText
          visible: root.steamActiveTab === "notinstalled" && root.steamNotInstalledLoaded && root.steamNotInstalled.length > 0
            && root.filteredSteamNotInstalled.length === 0 && root.steamSearchQuery.trim() !== ""
          text: "No games match \"" + root.steamSearchQuery.trim() + "\"."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // ListView, not Repeater: a Repeater instantiates every delegate for
        // every model item immediately regardless of scroll position -- with
        // 500+ owned-but-uninstalled games common for a long-time account,
        // that meant 500+ live SteamGameCards each independently loading its
        // own box art the instant this tab opened. Confirmed the hard way on
        // this machine: quickshell's memory climbed past 8GB and had to be
        // force-killed. ListView only realizes delegates actually within (or
        // just outside, via cacheBuffer) the visible viewport, so opening
        // this tab now only ever loads box art for a handful of rows at a
        // time no matter how large the owned library is. Height is capped
        // to the same "N visible rows" budget as the installed list, with
        // its own internal scroll for the rest -- the outer popup Flickable
        // barely needs to scroll for this tab anymore since this block's
        // height no longer grows with the model size.
        ListView {
          id: notInstalledListView
          visible: root.steamActiveTab === "notinstalled"
          width: steamLauncherColumn.width
          height: {
            if (!visible || count === 0) return 0
            var rows = Math.min(steamLauncherPopup.steamVisibleRows, count)
            return rows * steamLauncherPopup.steamRowHeight + (rows - 1) * spacing
          }
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: steamLauncherPopup.steamRowHeight * 4
          model: root.steamActiveTab === "notinstalled" ? root.filteredSteamNotInstalled : []

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: SteamGameCard {
            required property var modelData
            game: modelData
            actionTooltip: "Install"
            hoverGlyph: ""
            showActionButton: true
            onActivated: root.installSteamApp(modelData.appid)
          }
        }
      }
    }
  }

  // Shared by both the installed and not-installed game lists so they look
  // identical (Alan's ask: "let's make the uninstalled games have the same
  // look with all details as installed games") -- the two Repeaters using
  // this only differ in which list they iterate and what the action button/
  // click does (Launch vs Install). Box art, description, tags, and the
  // achievement bar all come from the same `game` data shape either way --
  // see onSteamNotInstalledListed/onSteamNotInstalledAchievementsListed for
  // how a not-installed game's object gets the same fields populated.
  component SteamGameCard: Item {
    id: cardRoot
    required property var game
    property string actionTooltip: "Launch"
    property string hoverGlyph: "▶"
    // Installed games keep the plain click-anywhere-to-launch card (matches
    // how Steam's own library already works, no button needed). Not-
    // installed games get an explicit, always-visible "Install" button too
    // -- restores what a pre-card-parity version of this list had (a real
    // Button, not just a hover-only glyph) after Alan reported it missing;
    // the hover glyph alone wasn't a discoverable enough affordance for a
    // less familiar action like installing an owned-but-uninstalled game.
    property bool showActionButton: false
    signal activated()

    width: steamLauncherColumn.width
    implicitHeight: steamLauncherPopup.steamRowHeight

    readonly property bool isRunning: root.isGameRunning(cardRoot.game.stateFlags)
    readonly property bool isUpdating: root.isGameUpdating(cardRoot.game.stateFlags)

    Rectangle {
      anchors.fill: parent
      radius: Math.max(2, Style.cornerRadius)
      color: cardMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
    }

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(6)
      spacing: Style.space(4)

      // Row 1: name (left), status/recency/playtime (right).
      Item {
        width: parent.width
        implicitHeight: Math.max(nameText.implicitHeight, installButton.visible ? installButton.implicitHeight : 0)

        Text {
          id: nameText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: statusText.left
          anchors.rightMargin: Style.space(6)
          text: cardRoot.game.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: statusText
          textFormat: Text.PlainText
          anchors.right: installButton.visible ? installButton.left : parent.right
          anchors.rightMargin: installButton.visible ? Style.space(8) : 0
          text: cardRoot.isRunning ? "▶ Playing now"
            : cardRoot.isUpdating ? "⬇ Updating…"
            : root.relativeLastPlayed(cardRoot.game.lastPlayed) + root.playtimeSuffix(cardRoot.game.playtimeMinutes)
          color: (cardRoot.isRunning || cardRoot.isUpdating) ? Color.accent : Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: cardRoot.isRunning || cardRoot.isUpdating
        }

        // z above cardMouse (declared later, below, but at the default z:0)
        // so its own click is what actually fires, not swallowed by the
        // whole-card MouseArea sitting on top of it.
        Button {
          id: installButton
          visible: cardRoot.showActionButton
          z: 1
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: cardRoot.actionTooltip
          foreground: root.foreground
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.caption
          onClicked: cardRoot.activated()
        }
      }

      // Row 2: box art (left) + description/tags (right).
      Item {
        id: artDescriptionRow
        width: parent.width
        implicitHeight: Style.space(84)

        Image {
          id: gameArt
          // See the description/tags anchors below for why they pin to
          // this Image's own top/bottom rather than the row's.
          property bool triedFallback: false
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(44)
          height: Style.space(64)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          source: cardRoot.game.boxArt
          onStatusChanged: {
            if (status === Image.Error && !triedFallback) {
              triedFallback = true
              source = cardRoot.game.boxArtFallback
            }
          }
        }

        // Subtle hover affordance: a glyph centered on the art, only while
        // the row is hovered -- the row was already fully clickable, this
        // just makes that obvious at a glance.
        Rectangle {
          visible: cardMouse.containsMouse
          anchors.centerIn: gameArt
          width: Style.space(22)
          height: width
          radius: width / 2
          color: Qt.rgba(0, 0, 0, 0.55)

          Text {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: 1
            text: cardRoot.hoverGlyph
            color: "white"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Pinned to the box art's own top edge, not the row's -- gameArt is
        // vertically centered in this taller row, so anchoring to parent.top
        // would land a few px above the art's actual top instead of level
        // with it.
        Text {
          id: descriptionText
          textFormat: Text.PlainText
          anchors.left: gameArt.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.top: gameArt.top
          visible: cardRoot.game.descriptionLoaded
          text: cardRoot.game.description || "No description available."
          color: Qt.darker(root.foreground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }

        // Up to 5 genre tags from Steam's own store data. Pinned to the box
        // art's own bottom edge independently of the description's own
        // height -- a short description leaves a visible gap above the
        // tags rather than the two touching.
        Text {
          id: tagsText
          textFormat: Text.PlainText
          anchors.left: gameArt.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.bottom: gameArt.bottom
          height: visible ? implicitHeight : 0
          visible: cardRoot.game.descriptionLoaded && cardRoot.game.tags.length > 0
          text: cardRoot.game.tags.join(" · ")
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
          elide: Text.ElideRight
        }
      }

      // Row 3: achievement progress -- trophy left, bar expanded to fill
      // the row, numbers on the right. Steam's own local achievement-stat
      // cache, not the Web API -- see scripts/steam-achievements.py.
      // Three real states once a game's own store fetch has completed
      // (descriptionLoaded): a real progress bar (local stat cache exists),
      // "No achievements" (the store's own category tag rules them out
      // entirely), or "Not yet played" (the store confirms the game *has*
      // achievements, but there's no local unlock data at all -- common for
      // an owned-but-never-launched not-installed game, which has no way to
      // get a local stat cache yet). Omitted entirely only while genuinely
      // still pending (the store fetch for this game hasn't completed yet).
      Item {
        id: achievementRow
        visible: cardRoot.game.achievementsLoaded || cardRoot.game.achievementsStoreNone || cardRoot.game.descriptionLoaded
        width: parent.width
        implicitHeight: Style.space(20)

        readonly property bool hasAchievements: cardRoot.game.achievementsTotal > 0
        readonly property bool notYetPlayed: !hasAchievements && !cardRoot.game.achievementsStoreNone && cardRoot.game.descriptionLoaded
        readonly property real fraction: hasAchievements
          ? cardRoot.game.achievementsUnlocked / cardRoot.game.achievementsTotal
          : 0

        Text {
          id: trophyIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: ""
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: !achievementRow.hasAchievements && !achievementRow.notYetPlayed
          textFormat: Text.PlainText
          anchors.left: trophyIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "No achievements"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
        }

        Text {
          visible: achievementRow.notYetPlayed
          textFormat: Text.PlainText
          anchors.left: trophyIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "Not yet played"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.italic: true
        }

        Text {
          id: achievementLabel
          visible: achievementRow.hasAchievements
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: cardRoot.game.achievementsUnlocked + "/" + cardRoot.game.achievementsTotal
            + " — " + Math.round(achievementRow.fraction * 100) + "%"
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          id: achievementTrack
          visible: achievementRow.hasAchievements
          anchors.left: trophyIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.right: achievementLabel.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: parent.radius
            color: root.foreground
            width: Math.max(height, achievementTrack.width * achievementRow.fraction)
          }
        }
      }
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(cardRoot, cardRoot.actionTooltip)
      onExited: if (root.bar) root.bar.hideTooltip(cardRoot)
      onClicked: cardRoot.activated()
    }
  }

  // Renders Steam's tray icon, recoloring it to the bar foreground so it
  // stays visible on any theme (the raw icon keeps its baked-in fill and
  // disappears against a matching background otherwise).
  component TrayIcon: Item {
    id: trayIconRoot
    // Null (not required) now: Steam might not be running, in which case
    // there's no live SNI icon at all. fallbackFile covers "installed but
    // closed" (the same steam_tray_mono.png Steam ships still sits on disk
    // whether or not the client is currently running); when neither is
    // available (Steam genuinely not installed) the plain-text glyph below
    // is the last resort.
    property var icon: null
    property string fallbackFile: ""
    readonly property bool hasImage: !!icon || !!fallbackFile
    readonly property bool symbolic: icon ? root.iconIsSymbolic(icon) : true

    Image {
      id: trayIconImage
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      // Decode at physical pixels: IconImage uses the logical size,
      // which leaves PNG icons upscaled and blurry on HiDPI displays.
      sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      source: trayIconRoot.icon ? root.trayIconSource(trayIconRoot.icon)
        : trayIconRoot.fallbackFile ? "file://" + trayIconRoot.fallbackFile : ""
      // Kept as a hidden layer so the effect can sample it as a texture.
      visible: trayIconRoot.hasImage && !trayIconRoot.symbolic
      layer.enabled: trayIconRoot.hasImage && trayIconRoot.symbolic
    }

    MultiEffect {
      anchors.fill: trayIconImage
      source: trayIconImage
      visible: trayIconRoot.hasImage && trayIconRoot.symbolic
      colorization: 1.0
      colorizationColor: root.foreground
    }

    // Steam genuinely not installed: no live SNI icon, no local asset file
    // to fall back to either. A plain icon-font glyph beats rendering
    // nothing, and (unlike a color emoji) respects `color` so it blends in
    // with the theme the same way the recolored real icon does.
    Text {
      anchors.centerIn: parent
      visible: !trayIconRoot.hasImage
      text: ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: parent.height * 0.85
    }
  }

  TrayIcon {
    anchors.centerIn: parent
    // Style.space(12) was the generic multi-icon system-tray convention
    // (icon.qml/Tray.qml uses it for a drawer full of small SNI pixmaps).
    // This plugin is a single dedicated bar icon now, not a tray drawer, so
    // it should match the "optical canvas" size every other dedicated
    // bar-widget icon uses (BarIconButton's opticalSize) rather than
    // looking undersized next to them -- Alan: "the plugin icon still
    // seems a bit off... maybe it's too small compared to other ones".
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    icon: root.steamItem ? root.steamItem.icon : null
    fallbackFile: (!root.steamItem && root.steamInstalled)
      ? (Quickshell.env("HOME") + "/.local/share/Steam/public/steam_tray_mono.png") : ""
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, "Steam Launcher")
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onPressed: function(mouse) {
      // No-op when Steam isn't running: openTrayMenu already guards on a
      // null item, and there's no live DBusMenu to show without one.
      if (mouse.button === Qt.RightButton && root.steamItem) {
        root.openTrayMenu(root.steamItem, root, mouse)
        mouse.accepted = true
      }
    }
    onClicked: function(mouse) {
      // Left-click always opens the launcher regardless of whether Steam
      // is currently running -- the popup's own content (games list,
      // launching via steam:// URIs) doesn't need Steam's tray item at
      // all, only right-click/middle-click (Steam's own live menu and
      // SecondaryActivate) genuinely require it to exist.
      if (mouse.button === Qt.RightButton) {
        mouse.accepted = true
      } else if (mouse.button === Qt.MiddleButton) {
        if (root.steamItem) root.steamItem.secondaryActivate()
      } else if (root.steamPopupOpen) {
        // Toggle closed on a second click rather than re-opening (which
        // used to just re-run the same open logic and re-show the popup
        // that was already showing -- never actually closing it).
        root.close()
      } else {
        // Steam's tray icon never implements the SNI Activate() call
        // left-click sends, and its own context menu carries no icons or
        // info anyway, so left-click always opens the quick-launcher
        // instead (right-click above still reaches the real menu).
        root.openSteamLauncher(root)
      }
    }
    onWheel: function(wheel) {
      if (root.steamItem) root.steamItem.scroll(wheel.angleDelta.y, false)
    }
  }
}
