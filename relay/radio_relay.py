#!/usr/bin/env python3
"""Burrito Radio relay: turns YouTube (and other) links into MP3 files GMod can play.

Garry's Mod plays audio with BASS (sound.PlayURL), which reads MP3/OGG over plain
HTTP(S). It cannot play YouTube: the page is not audio, and the real stream URLs
are Opus-in-WebM and locked to the IP that asked for them. So the game server asks
this relay to fetch a track once (yt-dlp), transcode it to a small MP3 (ffmpeg),
and keep it; every player then downloads the same file from here.

Two halves, two audiences:

  PUBLIC  (players' game clients, through EdgeGate at https://www.naliwajka.com/radio)
      GET  /radio/health                 {"ok": true, ...}
      GET  /radio/a/<key>.mp3            a ready track, with Range support so a
                                         player who walks up mid-song can seek

  CONTROL (the game server only: from 127.0.0.1, or with header X-Radio-Key)
      GET  /radio/resolve?q=<url|text>   a video, a playlist, a direct audio URL,
                                         or search words -> {"title", "tracks":[...]}
      GET  /radio/fetch?key=<key>        start fetching (idempotent) -> {"state": ...}
      GET  /radio/library                the owner's preloaded music
      GET  /radio/library/save?key=      keep a fetched track for good (preload it)
      GET  /radio/library/remove?key=    take it back out
      GET  /radio/library/rescan         pick up files dropped into library/

The public half never starts a download, so nobody on the internet can make this
box fetch anything: a key that is not already on disk is a 404.

Track keys:  yt-<11 char id>   url-<sha1 prefix>   lib-<sha1 prefix>

Owner preloads by dropping audio files (mp3, ogg, m4a, flac, wav, opus, webm) into
<data>/library/ (subfolders become the album name), or with the in-game "Save to
library" button. Library tracks are pinned: never evicted from the cache.

Config (environment, see naliwajka-radio.env):
  RADIO_LISTEN      0.0.0.0:8090
  RADIO_PREFIX      /radio
  RADIO_DATA        /var/lib/naliwajka-radio
  RADIO_KEY         shared secret for the control half from another host ('' = local only)
  RADIO_MAX_SECONDS 10800   longest track it will fetch (3 h: long lofi mixes are fine)
  RADIO_CACHE_MB    6000    evict least-recently-used unpinned tracks above this
  RADIO_BITRATE     96k     mono MP3: positional audio is mono anyway
  RADIO_YTDLP / RADIO_FFMPEG / RADIO_FFPROBE   binaries
  RADIO_PLAYLIST_MAX 500
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"

AUDIO_EXT = (".mp3", ".ogg", ".m4a", ".flac", ".wav", ".opus", ".webm", ".aac", ".wma")
KEY_RE = re.compile(r"^(yt|url|lib)-[A-Za-z0-9_-]{6,64}$")
YT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
YT_HOSTS = ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
            "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com")


def env(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


class Config:
    def __init__(self):
        host, _, port = env("RADIO_LISTEN", "0.0.0.0:8090").rpartition(":")
        self.host = host or "0.0.0.0"
        self.port = int(port)
        self.prefix = "/" + env("RADIO_PREFIX", "/radio").strip("/")
        if self.prefix == "/":
            self.prefix = ""
        self.data = env("RADIO_DATA", "/var/lib/naliwajka-radio")
        self.key = os.environ.get("RADIO_KEY", "")
        self.max_seconds = int(env("RADIO_MAX_SECONDS", "10800"))
        self.cache_bytes = int(env("RADIO_CACHE_MB", "6000")) * 1024 * 1024
        self.bitrate = env("RADIO_BITRATE", "96k")
        self.ytdlp = env("RADIO_YTDLP", "yt-dlp")
        self.ffmpeg = env("RADIO_FFMPEG", "ffmpeg")
        self.ffprobe = env("RADIO_FFPROBE", "ffprobe")
        self.playlist_max = int(env("RADIO_PLAYLIST_MAX", "500"))
        self.workers = int(env("RADIO_WORKERS", "2"))
        self.cache = os.path.join(self.data, "cache")
        self.library = os.path.join(self.data, "library")
        self.meta_file = os.path.join(self.data, "meta.json")


def sha(s, n=16):
    return hashlib.sha1(s.encode("utf-8", "replace")).hexdigest()[:n]


def youtube_ids(q):
    """(video_id, playlist_id) from a YouTube link, either may be None."""
    try:
        u = urllib.parse.urlparse(q.strip())
    except ValueError:
        return None, None
    host = (u.hostname or "").lower()
    if host not in YT_HOSTS:
        return None, None
    qs = urllib.parse.parse_qs(u.query)
    vid = None
    if host.endswith("youtu.be"):
        vid = u.path.strip("/").split("/")[0] or None
    elif u.path == "/watch":
        vid = (qs.get("v") or [None])[0]
    else:
        m = re.match(r"^/(?:shorts|embed|live|v)/([^/?#]+)", u.path)
        if m:
            vid = m.group(1)
    pl = (qs.get("list") or [None])[0]
    if vid and not YT_ID_RE.match(vid):
        vid = None
    if pl and not re.match(r"^[A-Za-z0-9_-]{10,64}$", pl):
        pl = None
    # Radio "mixes" (RD...) are endless and personalised: play the one video
    if pl and pl.startswith("RD"):
        pl = None if vid else pl
    return vid, pl


def clean_title(t):
    t = re.sub(r"\s+", " ", str(t or "")).strip()
    return t[:200] or "Untitled"


class Relay:
    def __init__(self, cfg):
        self.cfg = cfg
        os.makedirs(cfg.cache, exist_ok=True)
        os.makedirs(cfg.library, exist_ok=True)
        self.lock = threading.RLock()
        self.meta = self._load_meta()
        self.jobs = {}              # key -> Future
        self.errors = {}            # key -> (time, message)
        self.pool = ThreadPoolExecutor(max_workers=cfg.workers)
        self._dirty = False

    # ---------------------------------------------------------------- meta
    def _load_meta(self):
        try:
            with open(self.cfg.meta_file) as f:
                m = json.load(f)
            if isinstance(m, dict) and isinstance(m.get("tracks"), dict):
                return m
        except (OSError, ValueError):
            pass
        return {"tracks": {}}

    def save_meta(self):
        with self.lock:
            tmp = self.cfg.meta_file + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.meta, f, indent=1, sort_keys=True)
            os.replace(tmp, self.cfg.meta_file)

    def track(self, key):
        with self.lock:
            return self.meta["tracks"].get(key)

    def remember(self, key, **fields):
        with self.lock:
            t = self.meta["tracks"].setdefault(key, {})
            t.update({k: v for k, v in fields.items() if v is not None})
            return dict(t)

    def path(self, key):
        return os.path.join(self.cfg.cache, key + ".mp3")

    def ready(self, key):
        return KEY_RE.match(key or "") is not None and os.path.isfile(self.path(key))

    def touch(self, key):
        with self.lock:
            t = self.meta["tracks"].get(key)
            if t is not None:
                t["used"] = int(time.time())

    # ------------------------------------------------------------- resolve
    def run(self, args, timeout=120):
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

    def entry(self, key, title, duration, source, **extra):
        t = self.remember(key, title=clean_title(title),
                          duration=int(duration) if duration else None, source=source, **extra)
        return {"key": key, "title": t.get("title"), "duration": t.get("duration") or 0,
                "ready": self.ready(key)}

    def resolve(self, q):
        q = (q or "").strip()
        if not q:
            raise ValueError("nothing to play")
        if q.startswith("lib-") and KEY_RE.match(q):
            t = self.track(q)
            if not t:
                raise ValueError("no such library track")
            return {"title": t.get("title"), "tracks": [self.public_entry(q)]}
        vid, pl = youtube_ids(q)
        if pl:
            return self.resolve_playlist(pl)
        if vid:
            return self.resolve_video("https://www.youtube.com/watch?v=" + vid)
        if re.match(r"^https?://", q, re.I):
            return self.resolve_url(q)
        # plain words: the first YouTube search hit
        return self.resolve_video("ytsearch1:" + q[:200])

    def resolve_video(self, target):
        r = self.run([self.cfg.ytdlp, "--no-warnings", "--no-playlist", "--flat-playlist",
                      "-J", target], timeout=60)
        if r.returncode != 0:
            raise ValueError(last_line(r.stderr) or "could not read that video")
        d = json.loads(r.stdout)
        if d.get("_type") == "playlist":       # a search returns a 1-entry playlist
            ents = [e for e in d.get("entries") or [] if e]
            if not ents:
                raise ValueError("no results")
            d = ents[0]
        vid = d.get("id")
        if not vid or not YT_ID_RE.match(vid):
            raise ValueError("not a YouTube video")
        if d.get("is_live") or d.get("live_status") in ("is_live", "is_upcoming"):
            raise ValueError("live streams can't be played, only videos")
        if d.get("duration") and d["duration"] > self.cfg.max_seconds:
            raise ValueError("too long (over %d min)" % (self.cfg.max_seconds // 60))
        e = self.entry("yt-" + vid, d.get("title"), d.get("duration"),
                       "https://www.youtube.com/watch?v=" + vid)
        self.save_meta()
        return {"title": e["title"], "tracks": [e]}

    def resolve_playlist(self, pl):
        r = self.run([self.cfg.ytdlp, "--no-warnings", "--flat-playlist", "-J",
                      "--playlist-end", str(self.cfg.playlist_max),
                      "https://www.youtube.com/playlist?list=" + pl], timeout=120)
        if r.returncode != 0:
            raise ValueError(last_line(r.stderr) or "could not read that playlist")
        d = json.loads(r.stdout)
        out = []
        for e in d.get("entries") or []:
            if not e or not YT_ID_RE.match(str(e.get("id") or "")):
                continue
            title = e.get("title") or ""
            if title in ("[Private video]", "[Deleted video]"):
                continue
            if e.get("live_status") in ("is_live", "is_upcoming"):
                continue
            dur = e.get("duration")
            if dur and dur > self.cfg.max_seconds:
                continue
            out.append(self.entry("yt-" + e["id"], title, dur,
                                  "https://www.youtube.com/watch?v=" + e["id"]))
        self.save_meta()
        if not out:
            raise ValueError("that playlist has nothing playable")
        return {"title": clean_title(d.get("title") or "Playlist"), "tracks": out}

    def resolve_url(self, url):
        key = "url-" + sha(url)
        title = urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(url).path)) or url
        t = self.track(key) or {}
        e = self.entry(key, t.get("title") or title, t.get("duration"), url)
        self.save_meta()
        return {"title": e["title"], "tracks": [e]}

    def public_entry(self, key):
        t = self.track(key) or {}
        return {"key": key, "title": t.get("title") or key, "duration": t.get("duration") or 0,
                "ready": self.ready(key)}

    # --------------------------------------------------------------- fetch
    def status(self, key):
        if self.ready(key):
            t = self.track(key) or {}
            return {"state": "ready", "key": key, "duration": t.get("duration") or 0,
                    "title": t.get("title")}
        with self.lock:
            job = self.jobs.get(key)
            if job and not job.done():
                return {"state": "loading", "key": key}
            err = self.errors.get(key)
        if err:
            return {"state": "error", "key": key, "error": err[1]}
        return {"state": "missing", "key": key}

    def fetch(self, key):
        if not KEY_RE.match(key or ""):
            raise ValueError("bad key")
        if self.ready(key):
            self.touch(key)
            return self.status(key)
        t = self.track(key)
        if not t or not t.get("source"):
            raise ValueError("unknown track: resolve it first")
        with self.lock:
            job = self.jobs.get(key)
            if not (job and not job.done()):
                # a failure is retried only after a minute, so a broken video
                # in a playlist does not hammer YouTube every few seconds
                err = self.errors.get(key)
                if err and time.time() - err[0] < 60:
                    return self.status(key)
                self.errors.pop(key, None)
                self.jobs[key] = self.pool.submit(self._fetch, key, t["source"])
        return self.status(key)

    def _fetch(self, key, source):
        out = self.path(key)
        tmp = out + ".part"
        try:
            if key.startswith("yt-"):
                self._fetch_youtube(source, tmp)
            else:
                self._transcode(source, tmp)
            dur = self.probe(tmp)
            if dur <= 0:
                raise ValueError("no audio in that file")
            os.replace(tmp, out)
            self.remember(key, duration=int(round(dur)), size=os.path.getsize(out),
                          used=int(time.time()))
            self.save_meta()
            self.evict()
        except Exception as e:  # noqa: BLE001 -- reported to the game as the error
            msg = str(e)[:300] or e.__class__.__name__
            with self.lock:
                self.errors[key] = (time.time(), msg)
            log("fetch %s failed: %s" % (key, msg))
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def ffmpeg_args(self, src, dst):
        return [self.cfg.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                "-vn", "-map_metadata", "-1", "-ac", "1", "-ar", "44100",
                "-t", str(self.cfg.max_seconds),
                "-c:a", "libmp3lame", "-b:a", self.cfg.bitrate, "-f", "mp3", dst]

    def _fetch_youtube(self, source, tmp):
        work = tmp + ".src"
        r = self.run([self.cfg.ytdlp, "--no-warnings", "--no-playlist", "-f", "bestaudio/best",
                      "--match-filter", "duration <= %d" % self.cfg.max_seconds,
                      "--max-filesize", "400M", "-o", work + ".%(ext)s",
                      "--print", "after_move:filepath", source], timeout=900)
        got = [ln for ln in r.stdout.splitlines() if ln.strip()]
        if r.returncode != 0 or not got or not os.path.isfile(got[-1]):
            if "does not pass filter" in (r.stdout + r.stderr):
                raise ValueError("too long (over %d min)" % (self.cfg.max_seconds // 60))
            raise ValueError(last_line(r.stderr) or "download failed")
        try:
            self._transcode(got[-1], tmp)
        finally:
            for f in got:
                try:
                    os.unlink(f)
                except OSError:
                    pass

    def _transcode(self, src, tmp):
        r = self.run(self.ffmpeg_args(src, tmp), timeout=1800)
        if r.returncode != 0:
            raise ValueError(last_line(r.stderr) or "transcode failed")

    def probe(self, path):
        r = self.run([self.cfg.ffprobe, "-v", "error", "-show_entries", "format=duration",
                      "-of", "default=nw=1:nk=1", path], timeout=60)
        try:
            return float(r.stdout.strip())
        except ValueError:
            return 0.0

    def evict(self):
        with self.lock:
            files = []
            total = 0
            for name in os.listdir(self.cfg.cache):
                if not name.endswith(".mp3"):
                    continue
                key = name[:-4]
                p = os.path.join(self.cfg.cache, name)
                size = os.path.getsize(p)
                total += size
                t = self.meta["tracks"].get(key) or {}
                if t.get("pinned"):
                    continue
                files.append((t.get("used") or 0, key, p, size))
            files.sort()
            now = time.time()
            for used, key, p, size in files:
                if total <= self.cfg.cache_bytes:
                    break
                if now - used < 3600:      # may be playing right now
                    continue
                os.unlink(p)
                total -= size
                log("evicted %s" % key)

    # ------------------------------------------------------------- library
    def scan_library(self):
        """Every audio file under library/ becomes a pinned lib- track (transcoded once)."""
        seen = set()
        for root, _dirs, files in os.walk(self.cfg.library):
            for name in sorted(files):
                if not name.lower().endswith(AUDIO_EXT) or name.startswith("."):
                    continue
                p = os.path.join(root, name)
                rel = os.path.relpath(p, self.cfg.library)
                st = os.stat(p)
                key = "lib-" + sha(rel)
                seen.add(key)
                album = os.path.dirname(rel).replace(os.sep, " / ")
                t = self.track(key) or {}
                stale = t.get("mtime") != int(st.st_mtime) or t.get("bytes") != st.st_size
                self.remember(key, title=clean_title(os.path.splitext(name)[0]), album=album or None,
                              source=p, pinned=True, file=rel, mtime=int(st.st_mtime), bytes=st.st_size)
                if stale and os.path.exists(self.path(key)):
                    os.unlink(self.path(key))
                if not self.ready(key):
                    self.fetch(key)
        with self.lock:   # files the owner deleted
            for key in [k for k, t in self.meta["tracks"].items() if k.startswith("lib-") and k not in seen]:
                self.meta["tracks"].pop(key, None)
                try:
                    os.unlink(self.path(key))
                except OSError:
                    pass
        self.save_meta()

    def library(self):
        with self.lock:
            items = [(k, dict(t)) for k, t in self.meta["tracks"].items() if t.get("pinned")]
        out = []
        for k, t in items:
            out.append({"key": k, "title": t.get("title") or k, "duration": t.get("duration") or 0,
                        "album": t.get("album") or ("Saved" if not k.startswith("lib-") else ""),
                        "ready": self.ready(k)})
        out.sort(key=lambda e: (e["album"].lower(), e["title"].lower()))
        return {"tracks": out}

    def pin(self, key, on):
        if not KEY_RE.match(key or ""):
            raise ValueError("bad key")
        t = self.track(key)
        if not t:
            raise ValueError("unknown track")
        if key.startswith("lib-"):
            if not on:
                raise ValueError("files in library/ are removed by deleting the file")
            return self.status(key)
        self.remember(key, pinned=bool(on))
        if not on:
            with self.lock:
                self.meta["tracks"][key].pop("pinned", None)
        self.save_meta()
        if on and not self.ready(key):
            self.fetch(key)
        return self.status(key)


_OWN = {}


def own_address(ip):
    """Is `ip` one of this host's addresses? (We can bind to it only if it is.)"""
    if ip in ("127.0.0.1", "::1") or ip.startswith("127."):
        return True
    if ip not in _OWN:
        import socket
        try:
            s = socket.socket(socket.AF_INET6 if ":" in ip else socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.bind((ip, 0))
                _OWN[ip] = True
            finally:
                s.close()
        except OSError:
            _OWN[ip] = False
    return _OWN[ip]


def last_line(s):
    lines = [ln.strip() for ln in (s or "").splitlines() if ln.strip()]
    if not lines:
        return ""
    ln = lines[-1]
    return re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*[^:]+:\s*)?", "", ln)[:300]


def log(msg):
    sys.stderr.write("[radio] %s\n" % msg)
    sys.stderr.flush()


# ------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "BurritoRadio/" + VERSION
    relay = None  # set by serve()

    def log_message(self, fmt, *args):  # quiet: journald gets errors only
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def control_ok(self):
        """Same host (and not proxied), or the shared key.

        Same host is any address of this box, not just loopback: srcds binds its
        outgoing sockets to its -ip, so the game server's request to 127.0.0.1
        arrives FROM the box's LAN address (10.9.1.13)."""
        if own_address(self.client_address[0]) and not self.headers.get("X-Forwarded-For"):
            return True
        key = self.relay.cfg.key
        return bool(key) and self.headers.get("X-Radio-Key", "") == key

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        cfg = self.relay.cfg
        u = urllib.parse.urlparse(self.path)
        path = u.path
        if cfg.prefix:
            if not (path == cfg.prefix or path.startswith(cfg.prefix + "/")):
                return self.send_json({"error": "not found"}, 404)
            path = path[len(cfg.prefix):] or "/"
        qs = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        try:
            if path in ("/", "/health"):
                return self.send_json({"ok": True, "version": VERSION})
            m = re.match(r"^/a/([A-Za-z0-9_-]+)\.mp3$", path)
            if m:
                return self.send_audio(m.group(1))
            if not self.control_ok():
                return self.send_json({"error": "forbidden"}, 403)
            r = self.relay
            if path == "/resolve":
                return self.send_json(r.resolve(qs.get("q") or qs.get("url") or ""))
            if path == "/fetch":
                return self.send_json(r.fetch(qs.get("key", "")))
            if path == "/status":
                return self.send_json(r.status(qs.get("key", "")))
            if path == "/library":
                return self.send_json(r.library())
            if path == "/library/save":
                return self.send_json(r.pin(qs.get("key", ""), True))
            if path == "/library/remove":
                return self.send_json(r.pin(qs.get("key", ""), False))
            if path == "/library/rescan":
                r.scan_library()
                return self.send_json(r.library())
            return self.send_json({"error": "not found"}, 404)
        except ValueError as e:
            return self.send_json({"error": str(e)}, 400)
        except subprocess.TimeoutExpired:
            return self.send_json({"error": "timed out"}, 504)
        except Exception as e:  # noqa: BLE001
            log("error on %s: %r" % (path, e))
            return self.send_json({"error": "internal error"}, 500)

    def send_audio(self, key):
        r = self.relay
        if not r.ready(key):
            return self.send_json({"error": "not found"}, 404)
        r.touch(key)
        p = r.path(key)
        size = os.path.getsize(p)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        m = re.match(r"^bytes=(\d*)-(\d*)$", rng.strip())
        partial = False
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:  # suffix range: the last N bytes
                start = max(0, size - int(m.group(2)))
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            partial = True
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(p, "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass


def serve(cfg=None):
    cfg = cfg or Config()
    relay = Relay(cfg)
    Handler.relay = relay
    httpd = ThreadingHTTPServer((cfg.host, cfg.port), Handler)
    httpd.daemon_threads = True
    threading.Thread(target=relay.scan_library, daemon=True).start()
    log("v%s listening on %s:%d%s, data %s" % (VERSION, cfg.host, cfg.port, cfg.prefix, cfg.data))
    return httpd, relay


def main():
    for tool in ("ytdlp", "ffmpeg", "ffprobe"):
        exe = getattr(Config(), tool)
        if not shutil.which(exe):
            log("WARNING: %s not found (%s)" % (tool, exe))
    httpd, _ = serve()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
