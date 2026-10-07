#!/usr/bin/env python3
"""Reload Burrito Radio on a running GMod server and its connected players, no restart.

    RCON_PASSWORD=... tools/hotload.py <host> <port>

Copies tools/hotload.lua into garrysmod/lua/ over ssh (root@host) and runs it
through RCON. Deploy the files first (tools/deploy.sh <host> --addon)."""
import os
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _pkt(rid, typ, body):
    b = struct.pack("<ii", rid, typ) + body.encode() + b"\0\0"
    return struct.pack("<i", len(b)) + b


def _read(s):
    n = struct.unpack("<i", s.recv(4))[0]
    d = b""
    while len(d) < n:
        d += s.recv(n - len(d))
    rid, typ = struct.unpack("<ii", d[:8])
    return rid, typ, d[8:-2].decode(errors="replace")


def rcon(host, port, pw, cmd):
    s = socket.create_connection((host, port), timeout=5)
    s.sendall(_pkt(1, 3, pw))
    while True:
        rid, typ, _ = _read(s)
        if typ == 2:
            if rid == -1:
                raise PermissionError("rcon auth failed")
            break
    s.sendall(_pkt(2, 2, cmd))
    out = []
    s.settimeout(1.0)
    end = time.time() + 10
    while time.time() < end:
        try:
            out.append(_read(s)[2])
        except (socket.timeout, ConnectionError, struct.error):
            break
    s.close()
    return "".join(out)


def main():
    host, port = sys.argv[1], int(sys.argv[2])
    pw = os.environ["RCON_PASSWORD"]
    gm = os.environ.get("GM", "/opt/gmod/garrysmod")
    with open(os.path.join(HERE, "hotload.lua"), "rb") as f:
        subprocess.run(["ssh", "root@" + host, "install -o gmod -g gmod -m 0644 /dev/stdin %s/lua/bradio_hotload.lua" % gm],
                       stdin=f, check=True)
    print(rcon(host, port, pw, "lua_openscript bradio_hotload.lua").strip())


if __name__ == "__main__":
    main()
