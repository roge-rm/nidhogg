#!/usr/bin/env python3
"""Send Lua to the norns matron REPL and print what comes back.

Usage: tools/repl.py [-H host] [-w seconds] 'lua code'   (or Lua on stdin)
Port 5555 is matron, 5556 is SuperCollider (-p 5556).
"""
import argparse, base64, os, socket, struct, sys, time


def connect(host, port):
    s = socket.create_connection((host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((
        f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: bus.sp.nanomsg.org\r\n\r\n"
    ).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    if b" 101 " not in head.split(b"\r\n")[0]:
        sys.exit("handshake failed: " + head.decode(errors="replace"))
    return s


def send(s, text):
    data = text.encode()
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        hdr = struct.pack("!BB", 0x81, 0x80 | n)
    elif n < 65536:
        hdr = struct.pack("!BBH", 0x81, 0x80 | 126, n)
    else:
        hdr = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def recv_all(s, wait):
    out = b""
    end = time.time() + wait
    s.settimeout(0.1)
    buf = b""
    while time.time() < end:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            pass
        # unpack whole frames from buf
        while len(buf) >= 2:
            n = buf[1] & 0x7F
            i = 2
            if n == 126:
                if len(buf) < 4:
                    break
                n = struct.unpack("!H", buf[2:4])[0]
                i = 4
            elif n == 127:
                if len(buf) < 10:
                    break
                n = struct.unpack("!Q", buf[2:10])[0]
                i = 10
            if len(buf) < i + n:
                break
            out += buf[i:i + n]
            buf = buf[i + n:]
    return out.decode(errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-H", "--host", default=os.environ.get("NORNS_HOST", "norns.local"))
    ap.add_argument("-p", "--port", type=int, default=5555)
    ap.add_argument("-w", "--wait", type=float, default=1.0, help="seconds to collect output")
    ap.add_argument("code", nargs="?")
    a = ap.parse_args()
    code = a.code if a.code is not None else sys.stdin.read()
    if a.port == 5555 and "\n" in code.strip():
        # matron runs each line on its own, so send multi-line code as one load() call
        esc = code.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        code = f'assert(load("{esc}"))()'
    s = connect(a.host, a.port)
    send(s, code + "\n")
    sys.stdout.write(recv_all(s, a.wait))
    s.close()


if __name__ == "__main__":
    main()
