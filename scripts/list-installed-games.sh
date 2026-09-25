#!/bin/bash
# Lists locally installed Steam apps as
# "appid<TAB>name<TAB>stateFlags<TAB>sizeOnDisk" lines, one per app. Filtering
# out compat tools / non-games is left to the caller.
#
# stateFlags is Steam's own bitmask for the app's current install state
# (well-established community-documented values, consistent with this
# machine's own idle baseline of "4" == FullyInstalled and nothing else):
#   4=FullyInstalled 64=AppRunning 256=UpdateRunning 1024=UpdateStarted
#   131072=Downloading 262144=Staging 524288=Committing
# Read fresh on every popup open (same rescan as the rest of this file), so
# "is this game running / updating right now" reflects Steam's own live
# state without a separate polling mechanism.
#
# Covers every Steam library folder (see steam_libraries.py), not just the
# default one under ~/.local/share/Steam.

shopt -s nullglob
declare -A seen

manifests=()
while IFS= read -r lib; do
  manifests+=("$lib"/steamapps/appmanifest_*.acf)
done < <(python3 -B "$(dirname "$0")/steam_libraries.py")

for f in "${manifests[@]}"; do
  appid=$(grep -m1 '"appid"' "$f" | grep -oE '[0-9]+' | head -1)
  [[ -n "$appid" && -z ${seen[$appid]+_} ]] || continue
  seen[$appid]=1
  name=$(grep -m1 '"name"' "$f" | sed -E 's/^[[:space:]]*"name"[[:space:]]+"(.*)"[[:space:]]*$/\1/')
  stateFlags=$(grep -m1 '"StateFlags"' "$f" | grep -oE '[0-9]+' | head -1)
  sizeOnDisk=$(grep -m1 '"SizeOnDisk"' "$f" | grep -oE '[0-9]+' | head -1)
  [[ -n "$name" ]] && printf '%s\t%s\t%s\t%s\n' "$appid" "$name" "${stateFlags:-0}" "${sizeOnDisk:-0}"
done
