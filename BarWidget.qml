import Quickshell
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Io
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Ui

// Steam quick-launcher: a single bar icon that only appears while Steam is
// running (detected via its own StatusNotifierItem), replacing Steam's own
// left-click (which its Linux client never implements -- confirmed via
// D-Bus, only its right-click context menu works) with a popup listing your
// installed games -- box art + blurb from Steam's free/keyless CDN and
// store API, sorted by last-played (from Steam's own local play-history
// file), one click to launch. Right-click still gives Steam's real native
// menu (Store/Library/Friends/Settings/Exit) as a fallback.
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

  visible: root.steamItem !== null
  implicitWidth: root.trayItemExtent
  implicitHeight: root.trayItemExtent

  property bool trayMenuOpen: false
  property var activeTrayItem: null
  property var activeTrayAnchor: null

  property bool steamPopupOpen: false
  property var steamPopupAnchor: null
  property var steamGames: []
  property bool steamGamesLoading: false
  property bool steamGamesLoaded: false
  property var steamGamesPending: null
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
    // Rescan every open, not just the first: appmanifest_*.acf files come
    // and go as games are installed/uninstalled, with nothing to notify us
    // of that. The rescan itself is two cheap local reads (an ls-and-grep
    // over appmanifest files, a local VDF parse) -- no network -- and the
    // per-game description fetch is separately cache-gated (30 days), so
    // re-running this on every open costs nothing for games already known
    // and picks up anything installed/removed since the popup last opened.
    // A lingering steamGamesLoading only means a prior scan is still in
    // flight (e.g. opened twice in quick succession); don't stack another.
    if (!steamGamesLoading) loadSteamGames()
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
      var tab = line.indexOf("\t")
      if (tab === -1) continue
      var appid = line.slice(0, tab).trim()
      var name = line.slice(tab + 1).trim()
      if (!appid || !name || looksLikeSteamTool(name)) continue
      games.push({
        appid: appid,
        name: name,
        lastPlayed: 0,
        description: "",
        descriptionLoaded: false,
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

  function onSteamLastPlayedListed(raw) {
    var lastPlayed = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var tab = line.indexOf("\t")
      if (tab === -1) continue
      var appid = line.slice(0, tab).trim()
      var epoch = parseInt(line.slice(tab + 1).trim(), 10)
      if (appid && !isNaN(epoch)) lastPlayed[appid] = epoch
    }

    var games = (root.steamGamesPending || []).map(function(g) {
      var copy = Object.assign({}, g)
      copy.lastPlayed = lastPlayed[g.appid] || 0
      return copy
    })
    // Most recently played first; never-played games (0) sink to the bottom,
    // alphabetical among themselves and among same-timestamp ties.
    games.sort(function(a, b) {
      if (b.lastPlayed !== a.lastPlayed) return b.lastPlayed - a.lastPlayed
      return a.name.localeCompare(b.name)
    })

    root.steamGamesPending = null
    root.steamGames = games
    root.steamGamesLoading = false
    root.steamGamesLoaded = true
    for (var g = 0; g < games.length; g++) fetchSteamDescription(games[g].appid)
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
        root.setSteamGameField(appid, "descriptionLoaded", true)
        return
      }
    }
    var fetcher = steamDescriptionFetcher.createObject(root, { appid: appid })
    fetcher.start()
  }

  function cacheSteamDescription(appid, description) {
    var cache = Object.assign({}, root.descriptionCache)
    cache[appid] = { description: description, fetchedAt: Math.floor(Date.now() / 1000) }
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

  function trayTooltip(item) {
    if (!item) return ""
    return item.tooltipTitle || item.title || item.id || ""
  }

  FileView {
    id: descriptionCacheFile
    path: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.alanone.steam-launcher/cache/steam-descriptions.json"
    atomicWrites: true
    printErrors: false
    onLoaded: root.onDescriptionCacheLoaded(text())
    onLoadFailed: root.onDescriptionCacheLoaded("{}")
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

  // One short-lived curl process per game, fetching Steam's free/keyless
  // appdetails endpoint for a short blurb. Box art comes straight from the
  // CDN via Image.source instead (no API round trip needed for that part).
  Component {
    id: steamDescriptionFetcher

    Process {
      id: fetchProc
      required property string appid

      function start() {
        command = ["curl", "-fsS", "--max-time", "6",
          "https://store.steampowered.com/api/appdetails?appids=" + appid + "&filters=basic&l=english"]
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
              root.setSteamGameField(fetchProc.appid, "description", desc)
              root.cacheSteamDescription(fetchProc.appid, desc)
            }
          } catch (e) {
            // Leave description blank this run; the card still shows name + art.
          }
          root.setSteamGameField(fetchProc.appid, "descriptionLoaded", true)
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

  PopupCard {
    id: steamLauncherPopup
    anchorItem: root.steamPopupAnchor || root
    owner: root
    bar: root.bar
    open: root.steamPopupOpen
    padding: Style.space(10)
    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    contentWidth: steamLauncherPopup.fittedContentWidth(Style.space(560))
    // Capped to exactly 8 game rows tall (plus the fixed header above them):
    // computed from the header items' own implicitHeight and the row/spacing
    // constants the delegate below already uses, rather than a flat magic
    // pixel number, so this stays correct if those constants ever change.
    readonly property int steamRowHeight: Style.space(72)
    readonly property int steamVisibleRows: 8
    readonly property int steamHeaderHeight: steamTitleText.implicitHeight + steamLauncherColumn.spacing + steamButtonsRow.implicitHeight
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

        Text {
          id: steamTitleText
          text: "Steam"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Row {
          id: steamButtonsRow
          spacing: Style.space(6)

          Button {
            iconText: ""
            text: "Library"
            foreground: root.foreground
            horizontalPadding: 8
            verticalPadding: 3
            iconSize: Style.font.bodySmall
            fontSize: Style.font.bodySmall
            onClicked: root.openSteamUri("steam://open/games")
          }

          Button {
            iconText: ""
            text: "Big Picture"
            foreground: root.foreground
            horizontalPadding: 8
            verticalPadding: 3
            iconSize: Style.font.bodySmall
            fontSize: Style.font.bodySmall
            onClicked: root.openSteamUri("steam://open/bigpicture")
          }

          Button {
            iconText: "🥽"
            text: "VR"
            foreground: root.foreground
            horizontalPadding: 8
            verticalPadding: 3
            iconSize: Style.font.bodySmall
            fontSize: Style.font.bodySmall
            onClicked: root.openSteamUri("steam://open/vr")
          }
        }

        Text {
          visible: root.steamGamesLoading && root.steamGames.length === 0
          text: "Loading library…"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Text {
          visible: root.steamGamesLoaded && root.steamGames.length === 0
          text: "No installed games found."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        Repeater {
          model: root.steamGames

          delegate: Item {
            id: gameRow
            required property var modelData
            width: steamLauncherColumn.width
            implicitHeight: Style.space(72)

            Rectangle {
              anchors.fill: parent
              radius: Math.max(2, Style.cornerRadius)
              color: gameMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
            }

            Image {
              id: gameArt
              // A binding (source: failed ? fallback : boxArt) is cyclic --
              // status depends on source, and this would make source depend
              // back on status -- Qt flagged it as a binding loop and the two
              // URLs oscillated forever for any game lacking library art (e.g.
              // Cogs, Toki Tori only ship header.jpg, no library_600x900.jpg).
              // A one-shot imperative retry breaks the cycle: the assignment
              // in onStatusChanged detaches this from the initial binding.
              property bool triedFallback: false
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              height: Style.space(60)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: gameRow.modelData.boxArt
              onStatusChanged: {
                if (status === Image.Error && !triedFallback) {
                  triedFallback = true
                  source = gameRow.modelData.boxArtFallback
                }
              }
            }

            // Subtle hover affordance: a play glyph centered on the art, only
            // while the row is hovered -- the row was already fully clickable
            // to launch, this just makes that obvious at a glance.
            Rectangle {
              visible: gameMouse.containsMouse
              anchors.centerIn: gameArt
              width: Style.space(22)
              height: width
              radius: width / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 1
                text: ""
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Column {
              anchors.left: gameArt.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Item {
                width: parent.width
                implicitHeight: nameText.implicitHeight

                Text {
                  id: nameText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: recencyText.left
                  anchors.rightMargin: Style.space(6)
                  text: gameRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  id: recencyText
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  text: root.relativeLastPlayed(gameRow.modelData.lastPlayed)
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: gameRow.modelData.descriptionLoaded
                text: gameRow.modelData.description || "No description available."
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: gameMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: if (root.bar) root.bar.showTooltip(gameRow, "Launch")
              onExited: if (root.bar) root.bar.hideTooltip(gameRow)
              onClicked: root.launchSteamApp(gameRow.modelData.appid)
            }
          }
        }
      }
    }
  }

  // Renders Steam's tray icon, recoloring it to the bar foreground so it
  // stays visible on any theme (the raw icon keeps its baked-in fill and
  // disappears against a matching background otherwise).
  component TrayIcon: Item {
    id: trayIconRoot
    required property var icon
    readonly property bool symbolic: root.iconIsSymbolic(icon)

    Image {
      id: trayIconImage
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      // Decode at physical pixels: IconImage uses the logical size,
      // which leaves PNG icons upscaled and blurry on HiDPI displays.
      sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      source: root.trayIconSource(trayIconRoot.icon)
      // Kept as a hidden layer so the effect can sample it as a texture.
      visible: !trayIconRoot.symbolic
      layer.enabled: trayIconRoot.symbolic
    }

    MultiEffect {
      anchors.fill: trayIconImage
      source: trayIconImage
      visible: trayIconRoot.symbolic
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  TrayIcon {
    anchors.centerIn: parent
    width: Style.space(12)
    height: Style.space(12)
    icon: root.steamItem ? root.steamItem.icon : ""
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.trayTooltip(root.steamItem))
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.openTrayMenu(root.steamItem, root, mouse)
        mouse.accepted = true
      }
    }
    onClicked: function(mouse) {
      if (!root.steamItem) return
      if (mouse.button === Qt.RightButton) {
        mouse.accepted = true
      } else if (mouse.button === Qt.MiddleButton) {
        root.steamItem.secondaryActivate()
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
