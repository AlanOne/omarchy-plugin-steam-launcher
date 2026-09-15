#!/bin/bash
# Lists locally installed Steam apps as "appid<TAB>name" lines, one per app.
# Filtering out compat tools / non-games is left to the caller.

shopt -s nullglob
declare -A seen

for f in "$HOME"/.local/share/Steam/steamapps/appmanifest_*.acf "$HOME"/.steam/steam/steamapps/appmanifest_*.acf; do
  appid=$(grep -m1 '"appid"' "$f" | grep -oE '[0-9]+' | head -1)
  [[ -n "$appid" && -z ${seen[$appid]+_} ]] || continue
  seen[$appid]=1
  name=$(grep -m1 '"name"' "$f" | sed -E 's/^[[:space:]]*"name"[[:space:]]+"(.*)"[[:space:]]*$/\1/')
  [[ -n "$name" ]] && printf '%s\t%s\n' "$appid" "$name"
done
