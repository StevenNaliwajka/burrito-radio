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
      GET  /radio/resolve?q=<url|text>   a YouTube video or playlist, a Spotify track,
                                         album or playlist (matched to YouTube), or
                                         search words -> {"title", "tracks":[...]}
      GET  /radio/fetch?key=<key>        start fetching (idempotent) -> {"state": ...}
      GET  /radio/library                the owner's preloaded music
      GET  /radio/library/save?key=      keep a fetched track for good (preload it)
      GET  /radio/library/remove?key=    take it back out
      GET  /radio/library/rescan         pick up files dropped into library/

The public half never starts a download, so nobody on the internet can make this
box fetch anything: a key that is not already on disk is a 404.

Track keys:  yt-<11 char id>   sp-<spotify track id>   lib-<sha1 prefix>

ONLY YOUTUBE (and Spotify, which is matched to the same song on YouTube: its own
audio is DRM'd). Anything else is refused, on purpose: an arbitrary URL would make
this box fetch whatever a player typed (internal addresses included). Everything
fed to yt-dlp is a URL WE build from a validated id; yt-dlp may only use its
YouTube extractors and reads no config or plugins; ffmpeg may only open the local
file yt-dlp wrote, and re-encodes it from scratch (no metadata, no attachments),
so what players download is a plain MP3 this box made.

CACHE: a song nobody has used for RADIO_CACHE_TTL (30 min) is deleted; "used" is
a player downloading it or the game server's keep-alive while it plays. Library
songs (the owner's preloads) are kept.

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
  RADIO_CACHE_TTL   1800    delete unpinned songs unused for this long (seconds)
  RADIO_BITRATE     96k     mono MP3: positional audio is mono anyway
  RADIO_YTDLP / RADIO_FFMPEG / RADIO_FFPROBE   binaries
  RADIO_PLAYLIST_MAX 500
"""
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"

AUDIO_EXT = (".mp3", ".ogg", ".m4a", ".flac", ".wav", ".opus", ".webm", ".aac", ".wma")
KEY_RE = re.compile(r"^(yt|sp|lib)-[A-Za-z0-9_-]{6,64}$")
SP_ID_RE = re.compile(r"^[A-Za-z0-9]{22}$")
SP_HOSTS = ("open.spotify.com", "play.spotify.com")
YTDLP_SAFE = ["--ignore-config", "--no-plugin-dirs", "--no-warnings",
              "--use-extractors", "youtube,youtube:tab,youtube:playlist,youtube:search"]
MAX_QUERY = 500
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
        self.cache_ttl = int(env("RADIO_CACHE_TTL", "1800"))
        self.max_conns = int(env("RADIO_MAX_CONNECTIONS", "64"))
        self.max_lookups = int(env("RADIO_MAX_LOOKUPS", "3"))
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


def spotify_ids(q):
    """(kind, id) from a Spotify link or URI: track / album / playlist, else (None, None)."""
    q = q.strip()
    m = re.match(r"^spotify:(track|album|playlist):([A-Za-z0-9]{22})$", q)
    if m:
        return m.group(1), m.group(2)
    try:
        u = urllib.parse.urlparse(q)
    except ValueError:
        return None, None
    if u.scheme != "https" or (u.hostname or "").lower() not in SP_HOSTS:
        return None, None
    m = re.match(r"^/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?(?:embed/)?(track|album|playlist)/([A-Za-z0-9]{22})/?$", u.path)
    return (m.group(1), m.group(2)) if m else (None, None)


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
        self.lookups = threading.BoundedSemaphore(cfg.max_lookups)
        self.scanned = threading.Event()     # the first library scan has finished
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
        t = self.remember(key, title=clean_title(title), seen=int(time.time()),
                          duration=int(duration) if duration else None, source=source, **extra)
        return {"key": key, "title": t.get("title"), "duration": t.get("duration") or 0,
                "ready": self.ready(key)}

    def resolve(self, q):
        q = (q or "").strip()
        if not q:
            raise ValueError("nothing to play")
        if len(q) > MAX_QUERY:
            raise ValueError("that is too long")
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
        kind, sid = spotify_ids(q)
        if kind:
            return self.resolve_spotify(kind, sid)
        if re.match(r"^[a-z][a-z0-9+.-]*:", q, re.I) or re.search(r"\.[a-z]{2,}/", q, re.I):
            raise ValueError("only YouTube and Spotify links (or type a song name)")
        # plain words: the first YouTube search hit
        return self.resolve_video("ytsearch1:" + clean_search(q))

    def resolve_video(self, target):
        r = self.run([self.cfg.ytdlp] + YTDLP_SAFE + ["--no-playlist", "--flat-playlist",
                      "-J", "--", target], timeout=60)
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
        r = self.run([self.cfg.ytdlp] + YTDLP_SAFE + ["--flat-playlist", "-J",
                      "--playlist-end", str(self.cfg.playlist_max),
                      "--", "https://www.youtube.com/playlist?list=" + pl], timeout=120)
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

    def spotify_page(self, kind, sid):
        """The track list from Spotify's public embed page (no API key). The URL is
        built here from a validated 22-char id, never taken from the player."""
        url = "https://open.spotify.com/embed/%s/%s" % (kind, sid)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read(4 * 1024 * 1024).decode("utf-8", "replace")
        m = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', body, re.S)
        if not m:
            raise ValueError("couldn't read that Spotify link")
        return json.loads(m.group(1))["props"]["pageProps"]["state"]["data"]["entity"]

    def resolve_spotify(self, kind, sid):
        try:
            e = self.spotify_page(kind, sid)
        except (OSError, ValueError, KeyError, TypeError) as ex:
            raise ValueError("couldn't read that Spotify link (%s)" % (str(ex)[:80] or "error"))
        if kind == "track":
            items = [{"uri": "spotify:track:" + sid, "title": e.get("name") or e.get("title"),
                      "subtitle": ", ".join(a.get("name", "") for a in e.get("artists") or []),
                      "duration": e.get("duration")}]
        else:
            items = (e.get("trackList") or [])[: self.cfg.playlist_max]
        out = []
        for it in items:
            tid = str(it.get("uri") or "").rsplit(":", 1)[-1]
            title = clean_title(it.get("title"))
            artist = clean_title(re.sub(r"\s+", " ", str(it.get("subtitle") or "")).replace("\xa0", " "))
            if not SP_ID_RE.match(tid) or not it.get("title"):
                continue
            dur = int((it.get("duration") or 0) / 1000) or None
            if dur and dur > self.cfg.max_seconds:
                continue
            name = "%s - %s" % (artist, title) if artist and artist != "Untitled" else title
            out.append(self.entry("sp-" + tid, name, dur, None, search=clean_search(name + " audio")))
        self.save_meta()
        if not out:
            raise ValueError("nothing playable in that Spotify link")
        return {"title": clean_title(e.get("name") or e.get("title") or "Spotify"), "tracks": out}

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
        if not t or not (t.get("source") or t.get("search")):
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
                self.jobs[key] = self.pool.submit(self._fetch, key, t.get("source") or "")
        return self.status(key)

    def _fetch(self, key, source):
        out = self.path(key)
        tmp = out + ".part"
        try:
            if key.startswith("sp-"):
                source = self.match_on_youtube(key)
            if key.startswith(("yt-", "sp-")):
                self._fetch_youtube(source, tmp)
            elif key.startswith("lib-"):
                lib = os.path.realpath(self.cfg.library)
                real = os.path.realpath(source)
                if not real.startswith(lib + os.sep):
                    raise ValueError("library files must be inside library/")
                self._transcode(real, tmp)
            else:
                raise ValueError("unsupported track")
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

    def match_on_youtube(self, key):
        """A Spotify song is played from its YouTube twin: the first search hit."""
        t = self.track(key) or {}
        if t.get("yt") and YT_ID_RE.match(t["yt"]):
            return "https://www.youtube.com/watch?v=" + t["yt"]
        r = self.run([self.cfg.ytdlp] + YTDLP_SAFE + ["--flat-playlist", "-J", "--",
                      "ytsearch1:" + clean_search(t.get("search") or t.get("title") or "")], timeout=60)
        if r.returncode != 0:
            raise ValueError(last_line(r.stderr) or "no YouTube match")
        ents = [e for e in (json.loads(r.stdout).get("entries") or []) if e]
        vid = ents[0].get("id") if ents else None
        if not vid or not YT_ID_RE.match(vid):
            raise ValueError("no YouTube match for that song")
        self.remember(key, yt=vid)
        return "https://www.youtube.com/watch?v=" + vid

    def ffmpeg_args(self, src, dst):
        # only a local file in, only the audio out: no network, no other protocols,
        # no metadata or attachments carried into what players download
        return [self.cfg.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-protocol_whitelist", "file", "-i", "file:" + src,
                "-vn", "-map_metadata", "-1", "-ac", "1", "-ar", "44100",
                "-t", str(self.cfg.max_seconds),
                "-map", "0:a:0", "-dn", "-sn",
                "-c:a", "libmp3lame", "-b:a", self.cfg.bitrate, "-f", "mp3", "file:" + dst]

    def _fetch_youtube(self, source, tmp):
        work = tmp + ".src"
        if not re.match(r"^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$", source or ""):
            raise ValueError("not a YouTube video")
        r = self.run([self.cfg.ytdlp] + YTDLP_SAFE + ["--no-playlist", "-f", "bestaudio/best",
                      "--match-filter", "duration <= %d" % self.cfg.max_seconds,
                      "--max-filesize", "400M", "-o", work + ".%(ext)s",
                      "--print", "after_move:filepath", "--", source], timeout=900)
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

    def sweep(self, now=None):
        """The 30-minute rule: songs nobody has used for cache_ttl are deleted (the
        owner's library stays); half-written downloads and old bookkeeping too."""
        now = now or time.time()
        removed = []
        with self.lock:
            for name in os.listdir(self.cfg.cache):
                p = os.path.join(self.cfg.cache, name)
                if name.endswith((".part", ".src")) or ".part." in name or ".src." in name:
                    key = name.split(".")[0]
                    job = self.jobs.get(key)
                    if not (job and not job.done()) and now - os.path.getmtime(p) > 600:
                        os.unlink(p)
                    continue
                if not name.endswith(".mp3"):
                    continue
                key = name[:-4]
                t = self.meta["tracks"].get(key) or {}
                if t.get("pinned"):
                    continue
                used = t.get("used") or os.path.getmtime(p)
                if now - used > self.cfg.cache_ttl:
                    os.unlink(p)
                    removed.append(key)
            # forget songs nobody has touched in a week (they re-resolve if asked again)
            for key in [k for k, t in self.meta["tracks"].items()
                        if not t.get("pinned") and now - (t.get("used") or t.get("seen") or 0) > 7 * 86400
                        and not os.path.exists(self.path(k))]:
                self.meta["tracks"].pop(key, None)
            for key in [k for k, (ts, _) in self.errors.items() if now - ts > 3600]:
                self.errors.pop(key, None)
        if removed:
            log("cache: cleared %d song(s) unused for %d min" % (len(removed), self.cfg.cache_ttl // 60))
            self.save_meta()
        return removed

    def sweeper(self):
        while True:
            time.sleep(60)
            try:
                self.sweep()
            except Exception as e:  # noqa: BLE001
                log("sweep failed: %r" % e)

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
        self.scanned.set()

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


def clean_search(q):
    """Search words only: no option-looking text, no control characters."""
    q = re.sub(r"[\x00-\x1f\x7f]", " ", str(q))
    q = re.sub(r"\s+", " ", q).strip().lstrip("-")
    return q[:200] or "music"


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
    sys_version = ""
    relay = None  # set by serve()
    timeout = 30            # a slow or stalled client is dropped, not kept forever
    protocol_version = "HTTP/1.0"

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
        given = self.headers.get("X-Radio-Key", "")
        return bool(key) and hmac.compare_digest(given.encode(), key.encode())

    def do_HEAD(self):
        self.do_GET()

    def _refuse(self):
        self.send_json({"error": "method not allowed"}, 405)

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _refuse

    def do_GET(self):
        cfg = self.relay.cfg
        if len(self.path) > 2048:
            return self.send_json({"error": "too long"}, 414)
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
                # yt-dlp is heavy: a few lookups at a time, the rest asked to retry
                if not r.lookups.acquire(blocking=False):
                    return self.send_json({"error": "busy, try again in a moment"}, 429)
                try:
                    return self.send_json(r.resolve(qs.get("q") or qs.get("url") or ""))
                finally:
                    r.lookups.release()
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


class Server(ThreadingHTTPServer):
    """At most max_conns connections at once; past that, new ones are closed."""
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, addr, handler, max_conns):
        super().__init__(addr, handler)
        self.slots = threading.BoundedSemaphore(max_conns)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def serve(cfg=None):
    cfg = cfg or Config()
    relay = Relay(cfg)
    Handler.relay = relay
    httpd = Server((cfg.host, cfg.port), Handler, cfg.max_conns)
    threading.Thread(target=relay.scan_library, daemon=True).start()
    threading.Thread(target=relay.sweeper, daemon=True).start()
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
