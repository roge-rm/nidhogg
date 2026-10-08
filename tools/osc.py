#!/usr/bin/env python3
"""Send one OSC message over UDP. Arguments are typed by prefix:
i:3 (int), f:0.5 (float), s:text (string), b:903c7f (blob, hex).
Usage: tools/osc.py [-H host] [-p port] /path ARG..."""
import socket, struct, sys

def pad(b):
    return b + b"\0" * (4 - len(b) % 4)

def msg(path, args):
    tags, data = ",", b""
    for a in args:
        k, v = a.split(":", 1)
        if k == "i":
            tags += "i"; data += struct.pack(">i", int(v))
        elif k == "f":
            tags += "f"; data += struct.pack(">f", float(v))
        elif k == "s":
            tags += "s"; data += pad(v.encode())
        elif k == "b":
            raw = bytes.fromhex(v)
            tags += "b"; data += struct.pack(">i", len(raw)) + raw + b"\0" * ((4 - len(raw) % 4) % 4)
    return pad(path.encode()) + pad(tags.encode()) + data

argv = sys.argv[1:]
host, port = "127.0.0.1", 57140
while argv and argv[0] in ("-H", "-p"):
    if argv[0] == "-H": host = argv[1]
    else: port = int(argv[1])
    argv = argv[2:]
socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(msg(argv[0], argv[1:]), (host, port))
