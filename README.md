# Steam Launcher

A Steam icon for the Omarchy bar, always visible whether Steam is running, closed, or not
even installed. Left-click it for a quick-launcher popup: box art, a short blurb and genre
tags, achievement progress, total playtime, sorted by last-played (a running game always
floats to the top) — one click to launch. A second tab lists everything else you own with
the same detail — including real playtime/achievement history for something you played
years ago and later uninstalled — each with a one-click Install button instead. Right-click
gives you Steam's own native context menu as a fallback while Steam is running.

![Steam Launcher popup](preview.png)

## Why this exists

Steam's own Linux tray icon has never implemented the left-click "Activate" call every other
tray app responds to — confirmed directly over D-Bus, its `Activate()` method simply isn't
wired up. Only its right-click context menu does anything, and that menu carries no icons or
box art at all. This plugin gives left-click something worth doing instead: a real launcher.

## How it works

Everything here is a local file read or a free, keyless request — no Steam Web API key, no
login, nothing sent anywhere except to Steam's own public CDN/store API for art and blurbs.

- **Installed games** come from `appmanifest_*.acf` in every Steam library folder — the
  default one under `~/.local/share/Steam` plus every library Steam lists in its own
  `steamapps/libraryfolders.vdf` (a second drive, a `/mnt` mount, ...) — filtered to drop
  Proton/runtime/SteamVR compatibility entries that live in the same folders.
- **Last-played, playtime, and "Playing now"/"Updating…" status** come from Steam's own
  `localconfig.vdf` and each game's `StateFlags` bitmask — both already-local, already-yours
  data Steam maintains itself. A running game always sorts to the top.
- **Box art** loads straight from Steam's public CDN, falling back to a smaller image for
  games that don't ship the taller format.
- **Descriptions, genre tags, and achievement fallback** come from one request per game to
  Steam's free `store.steampowered.com/api/appdetails` endpoint, cached 30 days.
- **Achievement progress** is read from Steam's own local achievement-stat cache — a real bar
  once Steam has cached stats for a game (typically after playing it or viewing its
  achievements page), an italic "No achievements" for a game confirmed to have none (either
  locally, or via the store's own category tag for a game with no local cache at all), an
  italic "Not yet played" for a game the store confirms *does* have achievements but has no
  local stat cache yet (common for an owned-but-never-launched game), and nothing shown for a
  game that's genuinely unknown either way (the store fetch for it hasn't completed yet).
- **The "Not installed" tab** renders with the exact same card as an installed game — box
  art, description, tags, achievement progress, playtime — just with an Install button
  (`steam://install/<appid>`, which just asks Steam's own client to handle the download —
  this plugin never installs anything itself) in place of Launch. Names come from Steam's
  local `appinfo.vdf` cache, decoded by [`scripts/steam-not-installed.py`](scripts/steam-not-installed.py)
  and validated against every currently-installed game's real name before ever being trusted
  on an uninstalled one; playtime and achievements reuse the same local scripts as the
  installed list (neither is actually scoped to installed-only, so a game you played for
  hours years ago and later uninstalled still shows its real history). Loaded once, the
  first time you switch to that tab. Descriptions/tags for this list specifically go through
  a 3-at-a-time queue rather than firing one request per game — there can be hundreds of
  owned-but-uninstalled games, and Steam's store API has rate-limited far lighter use than
  that during this plugin's own development.
- **Rescanning** happens in the background, not on every popup open: a cheap check every few
  minutes (a handful of file-modification-time checks, not the real parsing) triggers a full
  rescan only when something's actually changed (a game installed/removed, last-played
  updated), with a several-hour fallback so it never goes stale even if a change is somehow
  missed. Opening the popup just shows whatever's already loaded — instantly, no waiting.
- The icon and right-click menu use the same StatusNotifierItem/DBusMenu protocol every tray
  icon uses; this plugin just recognizes Steam's specifically and gives it its own left-click.

Two Quickshell/Steam quirks worth knowing if you're reading the source (see the code comments
in `BarWidget.qml` for the full detail): Quickshell's icon loader doesn't actually honor the
`?path=` hint Steam's tray icon reports, so this plugin reads that file directly; and Steam's
tray icon uses Valve's own `_mono` naming convention (not freedesktop's `-symbolic`) for "please
recolor this," which this plugin's icon-tinting also recognizes.

## Prerequisites

- **Steam**, installed and already handling `steam://` URIs (true by default on any
  standard Steam-for-Linux install).
- **`curl`**, **`python3`**, and **ImageMagick** (`magick`) — `curl` for the description/box-art
  fetch, `python3` for local VDF/binary parsing, and ImageMagick to validate and re-encode
  downloaded box art before it's ever cached or rendered (see Security below). All three ship
  in Omarchy's base package set by default.

## Install

```sh
omarchy plugin add https://github.com/AlanOne/omarchy-plugin-steam-launcher.git --enable
```

## Usage

- **Left-click** the Steam icon to open the launcher. **Installed games** and **Not
  installed** tabs sit below the title row; clicking a tab switches the list and re-scopes
  the search box to it. Click any installed game to launch it, or click Install on an
  uninstalled one. The list shows up to 8 rows before scrolling.
- **Right-click** gives Steam's own native context menu (Store, Library, Friends, Settings,
  Exit, etc.) — only available while Steam is actually running.
- **Middle-click** forwards to Steam's own `SecondaryActivate`, same caveat.
- The icon is always visible. Everything works the same whether Steam is running or closed;
  only when Steam isn't *installed* does the popup show that explicitly instead of a games
  list. The icon itself falls back the same way: Steam's real icon while running, the same
  file read directly from disk while closed, a plain glyph if Steam isn't installed at all.

### Settings

Optional, on the widget's entry in `~/.config/omarchy/shell.json` (hot-reloads on save):

```json
{ "id": "io.github.alanone.steam-launcher", "libraryPaths": ["/mnt/games/SteamLibrary"] }
```

- **`libraryPaths`** — extra Steam library folders (the folder that *contains*
  `steamapps/`) to scan on top of the ones Steam already lists in `libraryfolders.vdf`.
  Array or colon-separated string. Only needed for libraries Steam itself doesn't know about.

Move the widget's position in the bar:

```sh
omarchy bar move io.github.alanone.steam-launcher --section right
```

## Remove

```sh
omarchy plugin remove io.github.alanone.steam-launcher
```

## Security

- Runs four external processes: `xdg-open` (for `steam://` URIs), `curl` (Steam's public store
  API and CDN), `python3` (local file parsing), and `magick` (box art validation, see below).
  Nothing else.
- The only network calls are to Steam's own CDN and store API — both public, keyless,
  read-only. No credentials are used or stored anywhere.
- Box art is never handed to the UI as a remote URL or as a raw download. `curl` fetches it
  under a byte cap and timeout into a temp file; `scripts/fetch-boxart.sh` then re-encodes that
  file through ImageMagick under a hard pixel-cache/memory ceiling, rejecting anything that
  isn't a plain JPEG/PNG, exceeds a fixed dimension ceiling, or can't be decoded within that
  ceiling. Only the resulting local, re-encoded file is ever rendered — a compromised or
  malicious CDN response can't hand the shell an oversized or malformed image to decode.
- Reads local files that are already entirely yours (`appmanifest_*.acf`, `localconfig.vdf`,
  the achievement stat cache, `appinfo.vdf`) — used only to build what's shown in the popup,
  never sent anywhere.
- Install only ever hands Steam a `steam://install/<appid>` URI and lets Steam's own client
  handle the rest.

## Troubleshooting

- **Games installed on another drive are missing**: the plugin reads every library listed in
  Steam's `libraryfolders.vdf` automatically; if a library still isn't picked up, add it via
  the `libraryPaths` setting above (see Settings).
- **Icon never appears**: it's always visible regardless of Steam's state, so this points at
  the plugin itself — check `omarchy restart shell` output for errors.
- **A game shows "No description available."**: Steam's store API occasionally rate-limits
  under heavy use — it'll pick up the description next time the cache entry is due to refresh.
- **Box art missing for one game**: not every game has the taller CDN image; this plugin
  falls back automatically, and leaves the slot blank rather than showing a broken image if
  neither exists (or if ImageMagick isn't installed, or rejects what it downloaded — see
  Security above).
- **A game shows "Not yet played" instead of a progress bar**: Steam only writes its local
  stat cache after you've opened that game's achievements page or played it at least once —
  play it or check its achievements in Steam once, then reopen the popup.
- **A change (new install, new achievement) doesn't show up immediately**: the popup shows
  whatever was loaded by the last background scan, not a live view — reopening it a few
  minutes later, or after actually using the game in question, should pick it up (see "How it
  works" above for the actual cadence).
- **A newly bought game doesn't show up in the "Not installed" tab right away, or a game you
  just installed through this plugin still shows there too**: that list is cached to disk for
  up to 24 hours (parsing `appinfo.vdf` for a large library is real work worth skipping on
  every popup open) — it'll pick up the change once that cache naturally expires.
- **Bar icon doesn't theme correctly after an update**: run
  `omarchy-shell shell rescanPlugins`; if that doesn't pick it up, `omarchy restart shell` will.

## License

MIT — see [LICENSE](LICENSE).
