#!/usr/bin/env python3
"""Every Steam library folder on this machine, one absolute path per line.

Steam can install games into any number of library folders (a second drive,
a /mnt mount, ...) and records all of them in its own
steamapps/libraryfolders.vdf. Scanning only ~/.local/share/Steam/steamapps
misses every game outside the default library, so everything that needs to
know "which games are installed" goes through library_dirs() instead.

Sources, merged and deduplicated in this order:
- The default Steam roots themselves (~/.local/share/Steam, ~/.steam/steam).
- Every "path" entry in each root's steamapps/libraryfolders.vdf.
- STEAM_LAUNCHER_LIBRARY_PATHS: extra library folders, colon-separated. The
  bar widget fills this from the plugin's `libraryPaths` setting in
  ~/.config/omarchy/shell.json, for libraries Steam itself doesn't list.

Only folders that actually contain a steamapps/ directory are returned.
"""

import os
import re

STEAM_ROOTS = ("~/.local/share/Steam", "~/.steam/steam")
ENV_EXTRA = "STEAM_LAUNCHER_LIBRARY_PATHS"

# libraryfolders.vdf is flat enough that a "path" key/value regex is all that's
# needed; VDF escapes backslashes inside quoted strings.
PATH_RE = re.compile(r'^\s*"path"\s+"((?:[^"\\]|\\.)*)"', re.IGNORECASE | re.MULTILINE)


def _vdf_library_paths(root):
    vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
    try:
        with open(vdf, "r", errors="replace") as f:
            text = f.read()
    except OSError:
        return []
    return [re.sub(r"\\(.)", r"\1", m) for m in PATH_RE.findall(text)]


def library_dirs():
    candidates = []
    for root in STEAM_ROOTS:
        root = os.path.expanduser(root)
        candidates.append(root)
        candidates.extend(_vdf_library_paths(root))
    candidates.extend(p for p in os.environ.get(ENV_EXTRA, "").split(":") if p.strip())

    seen = set()
    result = []
    for path in candidates:
        path = os.path.expanduser(path.strip())
        if not os.path.isdir(os.path.join(path, "steamapps")):
            continue
        real = os.path.realpath(path)  # ~/.steam/steam is usually a symlink to ~/.local/share/Steam
        if real in seen:
            continue
        seen.add(real)
        result.append(path)
    return result


if __name__ == "__main__":
    for d in library_dirs():
        print(d)
