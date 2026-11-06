#!/usr/bin/env python3
"""Give every tracked file and folder an mtime derived from its content.

A fresh checkout stamps everything with the current time, so a restored build cache sees all sources as changed.
The build system and the Swift driver compare mtimes for equality: the same content now keeps its mtime, and any
edit still changes it. A folder's hash covers everything inside it, which matters for asset catalogs.
shortcut: 28 bits of the hash can collide, a same-size edit would then be missed about once in 268 million.
"""
import os
import subprocess

JANUARY_2000 = 946684800

listing = subprocess.run(["git", "ls-tree", "-r", "-t", "-z", "HEAD"], check=True, capture_output=True, text=True).stdout
for entry in filter(None, listing.split("\0")):
    info, path = entry.split("\t", 1)
    stamp = JANUARY_2000 + int(info.split()[2][:7], 16)
    os.utime(path, (stamp, stamp), follow_symlinks=False)
