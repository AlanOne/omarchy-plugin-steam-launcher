#!/usr/bin/env python3
"""Print "appid<TAB>unlocked<TAB>total" for every locally installed game that
has achievement data cached, by reading Steam's own local binary stat cache
(~/.local/share/Steam/appcache/stats/UserGameStatsSchema_<appid>.bin for the
achievement definitions, UserGameStats_<accountid>_<appid>.bin for this
user's unlock state). Undocumented binary KeyValues format, decoded below.

A game with no UserGameStats_* file yet (Steam only writes one after you've
actually viewed that game's achievements or played it) or with zero
ACHIEVEMENTS-type stats is simply omitted -- not printed as 0/0.
"""
import glob
import os
import struct
import sys

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


def read_cstr(buf, pos):
    end = buf.index(b"\x00", pos)
    return buf[pos:end].decode("utf-8", errors="replace"), end + 1


def parse_object(buf, pos):
    obj = {}
    while True:
        t = buf[pos]
        pos += 1
        if t == TYPE_END:
            return obj, pos
        key, pos = read_cstr(buf, pos)
        if t == TYPE_OBJECT:
            val, pos = parse_object(buf, pos)
        elif t in (TYPE_STRING, TYPE_WSTRING):
            val, pos = read_cstr(buf, pos)
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


def parse_binary_vdf(path):
    with open(path, "rb") as f:
        buf = f.read()
    pos = 0
    t = buf[pos]
    pos += 1
    if t != TYPE_OBJECT:
        raise ValueError("not a binary VDF root object")
    _root_key, pos = read_cstr(buf, pos)
    obj, _pos = parse_object(buf, pos)
    return obj


def local_accountid():
    pattern = os.path.expanduser("~/.local/share/Steam/userdata/*/config/localconfig.vdf")
    files = glob.glob(pattern)
    if not files:
        return None
    newest = max(files, key=os.path.getmtime)
    # .../userdata/<accountid>/config/localconfig.vdf
    return os.path.basename(os.path.dirname(os.path.dirname(newest)))


def achievement_group_bit_ids(schema):
    """Stat group ids (schema's own keys, e.g. "1", "2") whose type is
    ACHIEVEMENTS, each mapped to the set of its *current* bit ids."""
    stats = schema.get("stats", {})
    groups = {}
    if not isinstance(stats, dict):
        return groups
    for gid, group in stats.items():
        if not isinstance(group, dict):
            continue
        if str(group.get("type", "")).upper() != "ACHIEVEMENTS":
            continue
        bits = group.get("bits", {})
        groups[gid] = set(bits.keys()) if isinstance(bits, dict) else set()
    return groups


def unlocked_count(user_stats, group_bit_ids):
    # A developer can remove/rename achievements over time, but a user's old
    # unlock timestamp for a since-removed bit id lingers in their local
    # stats file -- confirmed on a real game this session (Aqua Kitty,
    # appid 263880: schema currently has 2 bits in one group, but the user
    # file still carries 4 old timestamps there, 2 for ids no longer in the
    # schema). Intersecting against the *current* bit ids is what keeps
    # unlocked <= total; a raw len() of AchievementTimes can overcount.
    unlocked = 0
    for gid, bit_ids in group_bit_ids.items():
        group = user_stats.get(gid)
        if not isinstance(group, dict):
            continue
        times = group.get("AchievementTimes", {})
        if isinstance(times, dict):
            unlocked += len(bit_ids.intersection(times.keys()))
    return unlocked


def main():
    accountid = local_accountid()
    if not accountid:
        return

    stats_dir = os.path.expanduser("~/.local/share/Steam/appcache/stats")
    for schema_path in glob.glob(os.path.join(stats_dir, "UserGameStatsSchema_*.bin")):
        appid = os.path.basename(schema_path)[len("UserGameStatsSchema_"):-len(".bin")]
        user_path = os.path.join(stats_dir, f"UserGameStats_{accountid}_{appid}.bin")
        if not os.path.isfile(user_path):
            continue  # Steam hasn't fetched this user's stats for this game yet.

        try:
            schema_root = parse_binary_vdf(schema_path)
        except Exception:
            continue

        group_bit_ids = achievement_group_bit_ids(schema_root)
        total = sum(len(ids) for ids in group_bit_ids.values())
        if total <= 0:
            continue

        try:
            user_stats = parse_binary_vdf(user_path)
        except Exception:
            continue

        unlocked = unlocked_count(user_stats, group_bit_ids)
        print(f"{appid}\t{unlocked}\t{total}")


if __name__ == "__main__":
    main()
