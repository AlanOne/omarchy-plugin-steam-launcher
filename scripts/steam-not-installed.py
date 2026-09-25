#!/usr/bin/env python3
"""Print "appid<TAB>name" for every game Alan owns but hasn't installed,
sorted by name. Two local, keyless Steam caches, no network:

- ~/.local/share/Steam/userdata/<id>/config/localconfig.vdf's
  Software>Valve>Steam>apps keys list every appid Steam has ever written
  local per-user config for -- effectively "owned and touched at some
  point", built up over years of purchases. Same plaintext VDF format
  scripts/steam-last-played.py already parses (a fresh, self-contained
  copy of that parser lives below -- these scripts are meant to run
  standalone via `python3 <script>`; the one shared piece is
  steam_libraries.py, which lists every Steam library folder).
- ~/.local/share/Steam/appcache/appinfo.vdf carries a name (and type, so
  DLC/Tool/Config/Demo/etc. entries can be excluded, leaving actual games)
  for most apps Steam has ever loaded metadata for. This is a genuinely
  different, and more complex, binary format than the achievement stat
  cache's -- decoded and validated below.

appinfo.vdf format (magic 0x07564429, confirmed against this exact file):
  header: uint32 magic, uint32 universe, int64 string_table_offset
  then a sequence of per-app entries until a terminating appid of 0:
    uint32 appid, uint32 size (bytes remaining in this entry after this
    field), uint32 state, uint32 last_update, uint64 access_token,
    20 bytes sha1 (text), uint32 change_number, 20 bytes sha1 (binary)
    -- 60 fixed bytes total -- then a binary-VDF-encoded KeyValues blob
    filling the rest of the entry.
  Then, starting at string_table_offset: uint32 string count, followed by
  that many null-terminated UTF-8 strings back to back.

The per-app VDF blob uses the same type-tag encoding as the achievement
stat cache (TYPE_OBJECT=0x00 nested objects, TYPE_STRING=0x01, etc.) --
see scripts/steam-achievements.py for that format's origin -- except every
key is a uint32 *index into the shared string table* above, not an inline
null-terminated string. This indirection is the one genuinely new wrinkle
this format has over the achievement cache's: reusing common key names
("name", "type", "common", ...) as a shared string table across ~1200+
apps meaningfully shrinks the file, and Valve extended this format that
way at some point after the achievement cache's simpler format was fixed.

Validated against ground truth before trusting it: this script's parser
correctly recovers the real names (from appmanifest_<appid>.acf) of every
currently-installed game tested against it (CloverPit, Brotato, Braid,
Multiwinia, Toki Tori, Duck Game) before ever being pointed at an
owned-but-not-installed appid.
"""
import glob
import os
import re
import struct
import sys

sys.dont_write_bytecode = True  # keep the plugin checkout clean (no __pycache__)
from steam_libraries import library_dirs  # noqa: E402

# ---- appinfo.vdf (binary, string-table-indexed keys) ----

TYPE_OBJECT = 0x00
TYPE_STRING = 0x01
TYPE_INT32 = 0x02
TYPE_FLOAT32 = 0x03
TYPE_PTR = 0x04
TYPE_WSTRING = 0x05
TYPE_COLOR = 0x06
TYPE_UINT64 = 0x07
TYPE_END = 0x08
TYPE_INT64 = 0x0B


def parse_object_indexed(buf, pos, strings):
    obj = {}
    while True:
        t = buf[pos]
        pos += 1
        if t == TYPE_END:
            return obj, pos
        kidx = struct.unpack_from("<I", buf, pos)[0]
        pos += 4
        key = strings[kidx] if kidx < len(strings) else f"#{kidx}"
        if t == TYPE_OBJECT:
            val, pos = parse_object_indexed(buf, pos, strings)
        elif t in (TYPE_STRING, TYPE_WSTRING):
            end = buf.index(b"\x00", pos)
            val = buf[pos:end].decode("utf-8", errors="replace")
            pos = end + 1
        elif t in (TYPE_INT32, TYPE_COLOR, TYPE_PTR):
            val = struct.unpack_from("<i", buf, pos)[0]
            pos += 4
        elif t == TYPE_FLOAT32:
            val = struct.unpack_from("<f", buf, pos)[0]
            pos += 4
        elif t in (TYPE_UINT64, TYPE_INT64):
            val = struct.unpack_from("<q", buf, pos)[0]
            pos += 8
        else:
            raise ValueError(f"unknown binary VDF type 0x{t:02x}")
        obj[key] = val
    return obj, pos


def read_appinfo_names_and_types(path):
    """{appid: (name, type)} for every app appinfo.vdf carries a common
    section for. Best-effort: a corrupt/unexpected entry is skipped rather
    than aborting the whole file, since one bad app shouldn't hide the
    other ~1000+."""
    with open(path, "rb") as f:
        buf = f.read()

    magic = struct.unpack_from("<I", buf, 0)[0]
    if magic != 0x07564429:
        return {}  # A different appinfo.vdf revision; not handled here.

    string_table_offset = struct.unpack_from("<q", buf, 8)[0]

    pos = string_table_offset
    count = struct.unpack_from("<I", buf, pos)[0]
    pos += 4
    strings = []
    for _ in range(count):
        end = buf.index(b"\x00", pos)
        strings.append(buf[pos:end].decode("utf-8", errors="replace"))
        pos = end + 1

    result = {}
    pos = 16
    while pos < string_table_offset:
        appid = struct.unpack_from("<I", buf, pos)[0]
        if appid == 0:
            break
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        entry_start = pos + 8
        next_pos = entry_start + size
        vdf_start = entry_start + 60  # state+last_update+access_token+sha1+change_number+sha1
        try:
            obj, _ = parse_object_indexed(buf, vdf_start, strings)
            # The blob's root is itself a single-key wrapper object (key
            # "appinfo") around the actual fields -- same double-nesting
            # the achievement stat cache's binary VDF has (see
            # parse_binary_vdf's separate top-level type+key read there);
            # here it falls out of parse_object_indexed's own return value
            # instead, since that function starts consuming right at the
            # wrapper's own TYPE_OBJECT byte, not past it.
            appinfo = obj.get("appinfo", {})
            common = appinfo.get("common") if isinstance(appinfo, dict) else None
            if isinstance(common, dict):
                name = common.get("name")
                app_type = common.get("type")
                if isinstance(name, str) and name:
                    result[str(appid)] = (name, str(app_type or ""))
        except Exception:
            pass
        pos = next_pos
    return result


# ---- localconfig.vdf (plaintext VDF) -- same tokenizer approach as
# scripts/steam-last-played.py, copied rather than imported (each script
# here runs standalone). ----

TOKEN_RE = re.compile(r'"((?:[^"\\]|\\.)*)"|(\{)|(\})')


def unescape(s):
    return s.replace('\\"', '"').replace('\\\\', '\\')


def parse_vdf(text):
    tokens = []
    for m in TOKEN_RE.finditer(text):
        if m.group(1) is not None:
            tokens.append(('str', unescape(m.group(1))))
        elif m.group(2) is not None:
            tokens.append(('open', None))
        else:
            tokens.append(('close', None))

    pos = 0

    def parse_object():
        nonlocal pos
        obj = {}
        while pos < len(tokens):
            kind, value = tokens[pos]
            if kind == 'close':
                pos += 1
                return obj
            if kind != 'str':
                pos += 1
                continue
            key = value
            pos += 1
            if pos >= len(tokens):
                break
            nkind, nvalue = tokens[pos]
            if nkind == 'open':
                pos += 1
                obj[key] = parse_object()
            elif nkind == 'str':
                obj[key] = nvalue
                pos += 1
            else:
                obj[key] = None
        return obj

    if tokens and tokens[0][0] == 'str':
        pos = 1
        if pos < len(tokens) and tokens[pos][0] == 'open':
            pos += 1
            return parse_object()
    return {}


def find_key_ci(d, name):
    if not isinstance(d, dict):
        return None
    for k, v in d.items():
        if k.lower() == name.lower():
            return v
    return None


def owned_appids():
    pattern = os.path.expanduser("~/.local/share/Steam/userdata/*/config/localconfig.vdf")
    files = glob.glob(pattern)
    if not files:
        return set()
    path = max(files, key=os.path.getmtime)
    with open(path, "r", errors="replace") as f:
        text = f.read()
    node = parse_vdf(text)
    for key in ("Software", "Valve", "Steam", "apps"):
        node = find_key_ci(node, key)
        if node is None:
            return set()
    return set(node.keys())


def installed_appids():
    ids = set()
    for lib in library_dirs():
        for path in glob.glob(os.path.join(glob.escape(lib), "steamapps", "appmanifest_*.acf")):
            name = os.path.basename(path)
            ids.add(name[len("appmanifest_"):-len(".acf")])
    return ids


def main():
    owned = owned_appids()
    if not owned:
        return
    installed = installed_appids()
    not_installed = owned - installed
    if not not_installed:
        return

    appinfo_path = os.path.expanduser("~/.local/share/Steam/appcache/appinfo.vdf")
    if not os.path.isfile(appinfo_path):
        return
    names_and_types = read_appinfo_names_and_types(appinfo_path)

    rows = []
    for appid in not_installed:
        entry = names_and_types.get(appid)
        if not entry:
            continue  # No local metadata cached for this one -- skip rather than show a bare appid.
        name, app_type = entry
        if app_type.lower() != "game":
            continue  # DLC/Tool/Config/Demo/Music/etc. -- not something you'd "install" as a game.
        rows.append((appid, name))

    rows.sort(key=lambda r: r[1].lower())
    for appid, name in rows:
        print(f"{appid}\t{name}")


if __name__ == "__main__":
    main()
