#!/usr/bin/env python3
"""Hide / reorder GRUB boot entries by post-processing grub.cfg.

  grub-entries.py list   CFG HIDDEN ORDER            tab separated: shown|hidden, depth, title
  grub-entries.py filter CFG HIDDEN ORDER            hide + reorder CFG in place
  grub-entries.py move   CFG HIDDEN ORDER up|down T  move top-level entry T and save ORDER
"""
import re
import sys

START = re.compile(r"^\s*(menuentry|submenu)\s+(?:--\S+\s+)*(['\"])(.*?)\2")


def block_end(lines, i):
    depth, seen = 0, False
    for j in range(i, len(lines)):
        text = re.sub(r"'[^']*'|\"[^\"]*\"|#.*$", "", lines[j])
        depth += text.count("{") - text.count("}")
        seen = seen or "{" in text
        if seen and depth <= 0:
            return j
    return len(lines) - 1


def read_list(path):
    try:
        return [l.rstrip("\n") for l in open(path) if l.strip()]
    except FileNotFoundError:
        return []


def norm(title):
    # version numbers change on kernel updates; keep ordering stable across them
    return re.sub(r"\S*\d\S*", "#", title)


def top_level(lines):
    """[(title, kind, start, end)] for entries at brace depth 0."""
    out, depth, i = [], 0, 0
    while i < len(lines):
        m = START.match(lines[i]) if depth == 0 else None
        if m:
            end = block_end(lines, i)
            out.append((m.group(3), m.group(1), i, end))
            i = end + 1
            continue
        text = re.sub(r"'[^']*'|\"[^\"]*\"|#.*$", "", lines[i])
        depth += text.count("{") - text.count("}")
        i += 1
    return out


def children(lines, start, end):
    return [m.group(3) for l in lines[start + 1:end] if (m := START.match(l))]


def ordered(entries, order):
    keys = [norm(t) for t in order]
    rank = lambda e: keys.index(norm(e[0])) if norm(e[0]) in keys else len(keys)
    return sorted(entries, key=rank)


def apply(lines, hidden, order):
    out, i = [], 0
    while i < len(lines):
        m = START.match(lines[i])
        if m and m.group(3) in hidden:
            i = block_end(lines, i) + 1
            continue
        out.append(lines[i])
        i += 1
    entries = top_level(out)
    slots = [(s, e) for _, _, s, e in entries]
    blocks = [out[s:e + 1] for _, _, s, e in ordered(entries, order)]
    result, pos = [], 0
    for (s, e), block in zip(slots, blocks):
        result += out[pos:s] + block
        pos = e + 1
    return result + out[pos:]


def main():
    cmd, cfg, hidden_path, order_path = sys.argv[1:5]
    hidden, order = read_list(hidden_path), read_list(order_path)
    lines = open(cfg).read().splitlines(keepends=True)
    if cmd == "filter":
        if hidden or order:
            open(cfg, "w").write("".join(apply(lines, hidden, order)))
    elif cmd == "list":
        entries = ordered(top_level(lines), order)
        seen = set()
        for title, _, s, e in entries:
            print(f"shown\t0\t{title}")
            seen.add(title)
            for c in children(lines, s, e):
                print(f"shown\t1\t{c}")
                seen.add(c)
        for t in hidden:
            if t not in seen:
                print(f"hidden\t0\t{t}")
    elif cmd == "move":
        direction, title = sys.argv[5:7]
        titles = [t for t, *_ in ordered(top_level(lines), order)]
        if title in titles:
            i = titles.index(title)
            j = i - 1 if direction == "up" else i + 1
            if 0 <= j < len(titles):
                titles[i], titles[j] = titles[j], titles[i]
            open(order_path, "w").write("\n".join(titles) + "\n")


main()
