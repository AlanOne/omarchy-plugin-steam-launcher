#!/bin/bash
# Bounded, cached fetch of a game's box art from Steam's CDN, called once per
# realized SteamGameCard delegate. Security fix for marketplace issue #7151:
# BarWidget.qml used to hand the raw CDN URL straight to Image.source, which
# has no way to cap the HTTP response size or enforce a timeout -- a
# compromised/misbehaving CDN edge could return an arbitrarily large or
# slow-to-arrive body and exhaust memory in the shared Quickshell process.
# This downloads through curl instead, which enforces both, and only ever
# hands QML a bounded local file to render.
#
# Usage: fetch-boxart.sh <dest-path> <primary-url> [fallback-url]
set -u

dest="$1"
primary_url="$2"
fallback_url="${3:-}"

# Box art doesn't meaningfully change for a given appid once published --
# an existing cached file is trusted indefinitely, so a re-realized card
# (e.g. scrolled back into view) costs a single stat, not a network call.
if [ -s "$dest" ]; then
  exit 0
fi

tmp="${dest}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

try_fetch() {
  # --max-filesize caps the response at the curl level (independent of any
  # Content-Length header); --max-time bounds a slow/stalled connection. A
  # real library/header art file is well under 500KB, so 5MB leaves generous
  # headroom while still bounding what a bad response could hand back.
  # -o writes straight to a temp file -- image bytes never pass through QML.
  curl -fsSL --max-time 8 --max-filesize 5242880 --create-dirs -o "$tmp" -- "$1"
}

if try_fetch "$primary_url" || { [ -n "$fallback_url" ] && try_fetch "$fallback_url"; }; then
  mv -f "$tmp" "$dest"
  exit 0
fi

exit 1
