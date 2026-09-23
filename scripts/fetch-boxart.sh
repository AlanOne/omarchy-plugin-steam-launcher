#!/bin/bash
# Bounded, cached, validated fetch of a game's box art from Steam's CDN,
# called once per realized SteamGameCard delegate. Security fix for
# marketplace issue #7151:
# BarWidget.qml used to hand the raw CDN URL straight to Image.source, which
# has no way to cap the HTTP response size or enforce a timeout -- a
# compromised/misbehaving CDN edge could return an arbitrarily large or
# slow-to-arrive body and exhaust memory in the shared Quickshell process.
# This downloads through curl instead, which enforces both.
#
# The byte cap alone still let a small file decode-bomb the shell: a compact
# JPEG/PNG can legally declare a huge width/height, and QML's Image has no
# dimension ceiling of its own -- it'll try to allocate the full decoded
# buffer. So every downloaded file is re-encoded through ImageMagick under a
# hard pixel-cache limit before it's ever cached or handed to QML: real
# Steam art (largest known variant is library_600x900.jpg, 600x900) passes
# through untouched in substance; anything claiming more than MAX_DIM in
# either dimension, anything not a plain JPEG/PNG, or anything ImageMagick
# can't actually decode within the resource ceiling is rejected outright.
# QML only ever renders this locally re-encoded file, never the raw download.
#
# Usage: fetch-boxart.sh <dest-path> <primary-url> [fallback-url]
set -u

dest="$1"
primary_url="$2"
fallback_url="${3:-}"

# Real Steam art tops out at 900px (library_600x900.jpg); this leaves over
# 2x headroom for a future higher-res CDN variant while still bounding a
# malicious decode to a fixed, modest amount of memory.
max_dim=2000

# Box art doesn't meaningfully change for a given appid once published, and
# every file under dest_dir was already validated below at write time (the
# cache directory name is versioned specifically so a pre-validation cache
# from an older install of this plugin is never trusted -- see BarWidget.qml's
# boxArtCacheDir comment). So an existing cached file is trusted indefinitely,
# and a re-realized card (e.g. scrolled back into view) costs a single stat,
# not a network call or a re-decode.
if [ -s "$dest" ]; then
  exit 0
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "fetch-boxart.sh: ImageMagick ('magick') not found -- required to safely validate downloaded art" >&2
  exit 1
fi

raw="${dest}.raw.$$"
decoded="${dest}.tmp.$$"
trap 'rm -f "$raw" "$decoded"' EXIT

try_fetch() {
  # --max-filesize caps the response at the curl level (independent of any
  # Content-Length header); --max-time bounds a slow/stalled connection. A
  # real library/header art file is well under 500KB, so 5MB leaves generous
  # headroom while still bounding what a bad response could hand back.
  # -o writes straight to a temp file -- image bytes never pass through QML.
  curl -fsSL --max-time 8 --max-filesize 5242880 --create-dirs -o "$raw" -- "$1"
}

# Validates $raw is a plain, boundedly-sized JPEG/PNG and re-encodes it into
# $decoded. Every ImageMagick invocation here -- including the two identify
# probes, not just the final decode -- runs under the same pixel-cache
# ceiling AND a `timeout --kill-after`, confirmed empirically necessary:
# a 69-byte PNG whose header simply lies about being 60000x60000 made a
# *plain* `identify -format %w` (no -limit) sit for minutes, and a bare
# `timeout 5` alone did NOT kill it -- ImageMagick didn't exit on SIGTERM.
# -limit makes IM refuse the oversized allocation outright instead of
# grinding on it; --kill-after is the backstop in case some other crafted
# input finds a different way to ignore SIGTERM.
im_limits=(-limit memory 64MiB -limit map 64MiB -limit disk 32MiB -limit thread 1)
# NOTE: -limit must come AFTER the subcommand (identify/convert-style
# operands) -- `magick -limit ... identify ...` mis-parses "identify" as a
# filename and fails immediately, confirmed empirically.
bounded_identify() {
  local secs="$1"; shift
  timeout --kill-after=3 "$secs" magick identify "${im_limits[@]}" "$@"
}
bounded_convert() {
  local secs="$1"; shift
  timeout --kill-after=3 "$secs" magick "${im_limits[@]}" "$@"
}

validate_and_normalize() {
  local fmt dims w h
  fmt=$(bounded_identify 5 -format "%m" "${raw}[0]" 2>/dev/null) || return 1
  case "$fmt" in
    JPEG|PNG) ;;
    *) return 1 ;;
  esac

  dims=$(bounded_identify 5 -format "%w %h" "${raw}[0]" 2>/dev/null) || return 1
  read -r w h <<<"$dims"
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 1
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
  [ "$w" -le "$max_dim" ] && [ "$h" -le "$max_dim" ] || return 1

  # The actual bounded decode. The explicit "jpeg:"/"png:" read prefix
  # (rather than letting magick auto-sniff the format) uses exactly the
  # coder identify already confirmed the content matches, closing off
  # format-confusion tricks against IM's format auto-detection.
  local prefix
  case "$fmt" in
    JPEG) prefix=jpeg ;;
    PNG) prefix=png ;;
  esac
  bounded_convert 8 "${prefix}:${raw}" -auto-orient -strip "jpeg:${decoded}"
}

if try_fetch "$primary_url" || { [ -n "$fallback_url" ] && try_fetch "$fallback_url"; }; then
  if validate_and_normalize; then
    mv -f "$decoded" "$dest"
    exit 0
  fi
fi

exit 1
