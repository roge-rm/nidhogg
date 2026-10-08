#!/usr/bin/env python3
"""Chompi was written on a case-insensitive file system. For each quoted
#include in DIR that doesn't exist as written but does in another case, make a
symlink with the name as written."""
import os, re, sys

d = sys.argv[1]
names = {n.lower(): n for n in os.listdir(d)}
inc = re.compile(r'^\s*#\s*include\s*"([^"/]+)"', re.M)
for f in os.listdir(d):
    p = os.path.join(d, f)
    if not os.path.isfile(p):
        continue
    with open(p, errors="replace") as fh:
        for want in inc.findall(fh.read()):
            if not os.path.exists(os.path.join(d, want)) and want.lower() in names:
                os.symlink(names[want.lower()], os.path.join(d, want))
                names[want] = want
