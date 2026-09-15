#!/usr/bin/env python3
"""Print "appid<TAB>lastplayed_epoch" for every app with a LastPlayed entry
in the local Steam user's localconfig.vdf (KeyValues/VDF format). One line
per app, unsorted -- sorting is the caller's job.
"""
import glob
import os
import re
import sys

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


def main():
    pattern = os.path.expanduser("~/.local/share/Steam/userdata/*/config/localconfig.vdf")
    files = glob.glob(pattern)
    if not files:
        return
    path = max(files, key=os.path.getmtime)

    with open(path, "r", errors="replace") as f:
        text = f.read()

    root = parse_vdf(text)
    node = root
    for key in ("Software", "Valve", "Steam", "apps"):
        node = find_key_ci(node, key)
        if node is None:
            return

    for appid, entry in node.items():
        last_played = find_key_ci(entry, "LastPlayed") if isinstance(entry, dict) else None
        if last_played and str(last_played).isdigit():
            print(f"{appid}\t{last_played}")


if __name__ == "__main__":
    main()
