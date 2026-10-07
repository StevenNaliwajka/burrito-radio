"""relay/radio_relay.py against fake yt-dlp / ffmpeg / ffprobe: resolve, fetch, the
public/control split, Range requests, the library and eviction. No network."""
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "relay"))
import radio_relay as rr  # noqa: E402

FAKE_YTDLP = r'''#!/usr/bin/env python3
import json, sys, os
a = sys.argv[1:]
target = a[-1]
if "-J" in a:
    if "playlist?list=" in target:
        print(json.dumps({"_type": "playlist", "title": "Road Trip", "entries": [
            {"id": "aaaaaaaaaaa", "title": "One", "duration": 100},
            {"id": "bbbbbbbbbbb", "title": "[Deleted video]", "duration": None},
            {"id": "ccccccccccc", "title": "Too Long", "duration": 99999},
            {"id": "ddddddddddd", "title": "Two", "duration": 200}]}))
    elif target.startswith("ytsearch1:"):
        print(json.dumps({"_type": "playlist", "entries": [{"id": "eeeeeeeeeee", "title": "Found It", "duration": 150}]}))
    elif "v=lllllllllll" in target:
        print(json.dumps({"id": "lllllllllll", "title": "Live Now", "is_live": True, "live_status": "is_live"}))
    elif "v=ggggggggggg" in target:
        print(json.dumps({"id": "ggggggggggg", "title": "Ten Hour Loop", "duration": 36000}))
    elif "v=zzzzzzzzzzz" in target:
        sys.stderr.write("ERROR: [youtube] zzzzzzzzzzz: Video unavailable\n"); sys.exit(1)
    else:
        vid = target.split("v=")[1][:11]
        print(json.dumps({"id": vid, "title": "Video " + vid, "duration": 213}))
    sys.exit(0)
out = a[a.index("-o") + 1].replace("%(ext)s", "webm")
cnt = os.environ.get("FAKE_COUNT")
if cnt:
    open(cnt, "a").write(target + "\n")
if os.environ.get("FAKE_SLOW"):
    import time; time.sleep(float(os.environ["FAKE_SLOW"]))
if "v=fffffffffff" in target:
    sys.stderr.write("ERROR: [youtube] fffffffffff: Sign in to confirm your age\n"); sys.exit(1)
open(out, "wb").write(b"FAKEAUDIO" * 1000)
print(out)
'''
FAKE_FFMPEG = r'''#!/usr/bin/env python3
import sys, shutil
a = sys.argv[1:]
src = a[a.index("-i") + 1]
if src.startswith("http"):
    if "missing" in src:
        sys.stderr.write("Server returned 404 Not Found\n"); sys.exit(1)
    open(a[-1], "wb").write(b"URLAUDIO" * 500)
else:
    shutil.copy(src, a[-1])
'''
FAKE_FFPROBE = "#!/bin/sh\necho 213.4\n"


def write_exe(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        for name, body in (("yt-dlp", FAKE_YTDLP), ("ffmpeg", FAKE_FFMPEG), ("ffprobe", FAKE_FFPROBE)):
            write_exe(os.path.join(d, name), body)
        os.environ.update({
            "RADIO_LISTEN": "127.0.0.1:0", "RADIO_DATA": os.path.join(d, "data"),
            "RADIO_YTDLP": os.path.join(d, "yt-dlp"), "RADIO_FFMPEG": os.path.join(d, "ffmpeg"),
            "RADIO_FFPROBE": os.path.join(d, "ffprobe"), "RADIO_KEY": "sekrit", "RADIO_MAX_SECONDS": "3600",
            "RADIO_CACHE_MB": "1",
        })
        self.httpd, self.relay = rr.serve(rr.Config())
        self.base = "http://127.0.0.1:%d/radio" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.relay.pool.shutdown(wait=True)
        self.tmp.cleanup()

    def get(self, path, headers=None):
        req = urllib.request.Request(self.base + path, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def json(self, path, headers=None):
        code, body, _ = self.get(path, headers)
        return code, json.loads(body)

    def wait_ready(self, key):
        for _ in range(100):
            code, s = self.json("/status?key=" + key)
            if s["state"] != "loading":
                return s
            time.sleep(0.05)
        self.fail("never finished")

    def test_health(self):
        self.assertEqual(self.json("/health"), (200, {"ok": True, "version": rr.VERSION}))

    def test_video_link_variants(self):
        for link in ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ?t=5",
                     "https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share",
                     "https://www.youtube.com/shorts/dQw4w9WgXcQ",
                     "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&start_radio=1"):
            code, r = self.json("/resolve?q=" + urllib.request.quote(link, safe=""))
            self.assertEqual(code, 200, link)
            self.assertEqual([t["key"] for t in r["tracks"]], ["yt-dQw4w9WgXcQ"], link)

    def test_playlist_skips_deleted_and_too_long(self):
        code, r = self.json("/resolve?q=" + urllib.request.quote("https://www.youtube.com/playlist?list=PLabcdefghijk"))
        self.assertEqual(code, 200)
        self.assertEqual(r["title"], "Road Trip")
        self.assertEqual([t["title"] for t in r["tracks"]], ["One", "Two"])

    def test_search_words(self):
        code, r = self.json("/resolve?q=never+gonna+give+you+up")
        self.assertEqual(r["tracks"][0]["key"], "yt-eeeeeeeeeee")

    def test_fetch_then_serve_with_ranges(self):
        self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/dQw4w9WgXcQ"))
        code, s = self.json("/fetch?key=yt-dQw4w9WgXcQ")
        self.assertIn(s["state"], ("loading", "ready"))
        s = self.wait_ready("yt-dQw4w9WgXcQ")
        self.assertEqual(s["state"], "ready")
        self.assertEqual(s["duration"], 213)
        code, body, h = self.get("/a/yt-dQw4w9WgXcQ.mp3")
        self.assertEqual((code, len(body), h["Content-Type"]), (200, 9000, "audio/mpeg"))
        code, body, h = self.get("/a/yt-dQw4w9WgXcQ.mp3", {"Range": "bytes=100-199"})
        self.assertEqual((code, len(body), h["Content-Range"]), (206, 100, "bytes 100-199/9000"))
        code, body, h = self.get("/a/yt-dQw4w9WgXcQ.mp3", {"Range": "bytes=-10"})
        self.assertEqual((code, len(body)), (206, 10))
        code, _, _ = self.get("/a/yt-dQw4w9WgXcQ.mp3", {"Range": "bytes=99999-"})
        self.assertEqual(code, 416)

    def test_public_cannot_trigger_downloads(self):
        # through EdgeGate every request carries X-Forwarded-For: the control half wants the key
        fwd = {"X-Forwarded-For": "203.0.113.9"}
        self.assertEqual(self.get("/resolve?q=x", fwd)[0], 403)
        self.assertEqual(self.get("/fetch?key=yt-dQw4w9WgXcQ", fwd)[0], 403)
        self.assertEqual(self.get("/library/save?key=yt-dQw4w9WgXcQ", fwd)[0], 403)
        self.assertEqual(self.get("/a/yt-notdownloaded.mp3", fwd)[0], 404)
        ok = dict(fwd, **{"X-Radio-Key": "sekrit"})
        self.assertEqual(self.get("/library", ok)[0], 200)

    def test_same_host_on_its_lan_address_is_local(self):
        # srcds binds outgoing sockets to its -ip: the game server's request to the relay
        # on 127.0.0.1 can arrive from the box's own LAN address. Peer == our socket's
        # address means same host; anything else still needs the key.
        import socket
        ip = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("10.255.255.255", 1))
            ip = s.getsockname()[0]
            s.close()
        except OSError:
            pass
        if not ip or ip.startswith("127."):
            self.skipTest("no LAN address")
        port = self.httpd.server_address[1]
        self.httpd.server_close()
        self.httpd.shutdown()
        os.environ["RADIO_LISTEN"] = "0.0.0.0:%d" % port
        self.httpd, _ = rr.serve(rr.Config())
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        c = socket.create_connection(("127.0.0.1", port), source_address=(ip, 0))
        c.sendall(b"GET /radio/library HTTP/1.0\r\nHost: x\r\n\r\n")
        reply = c.recv(200).decode()
        c.close()
        self.assertIn(" 200 ", reply.splitlines()[0])
        self.assertTrue(rr.own_address(ip))
        self.assertFalse(rr.own_address("203.0.113.9"))

    def test_bad_keys_and_paths(self):
        self.assertEqual(self.get("/a/../../etc/passwd.mp3")[0], 404)
        self.assertEqual(self.json("/fetch?key=nope")[0], 400)
        self.assertEqual(self.json("/fetch?key=yt-neverresolved")[0], 400)
        code, body, _ = self.get("/../radio/health")
        self.assertIn(code, (200, 404))

    def test_download_errors_are_reported(self):
        self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/fffffffffff"))
        self.json("/fetch?key=yt-fffffffffff")
        s = self.wait_ready("yt-fffffffffff")
        self.assertEqual(s["state"], "error")
        self.assertIn("Sign in to confirm your age", s["error"])
        code, r = self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/zzzzzzzzzzz"))
        self.assertEqual(code, 400)
        self.assertIn("Video unavailable", r["error"])

    def test_library_files_and_saving(self):
        lib = self.relay.cfg.library
        os.makedirs(os.path.join(lib, "Chill"), exist_ok=True)
        with open(os.path.join(lib, "Chill", "Rainy Day.ogg"), "wb") as f:
            f.write(b"x" * 500)
        with open(os.path.join(lib, "notes.txt"), "w") as f:
            f.write("ignored")
        code, r = self.json("/library/rescan")
        self.assertEqual(code, 200)
        self.assertEqual([(t["album"], t["title"]) for t in r["tracks"]], [("Chill", "Rainy Day")])
        key = r["tracks"][0]["key"]
        self.assertEqual(self.wait_ready(key)["state"], "ready")
        # save a YouTube song into the library, then take it out again
        self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/dQw4w9WgXcQ"))
        self.json("/library/save?key=yt-dQw4w9WgXcQ")
        self.wait_ready("yt-dQw4w9WgXcQ")
        code, r = self.json("/library")
        self.assertEqual(sorted(t["title"] for t in r["tracks"]), ["Rainy Day", "Video dQw4w9WgXcQ"])
        self.json("/library/remove?key=yt-dQw4w9WgXcQ")
        code, r = self.json("/library")
        self.assertEqual([t["title"] for t in r["tracks"]], ["Rainy Day"])
        # the owner deletes the file: it leaves the library
        os.unlink(os.path.join(lib, "Chill", "Rainy Day.ogg"))
        code, r = self.json("/library/rescan")
        self.assertEqual(r["tracks"], [])

    def test_eviction_keeps_pinned_and_recent(self):
        r = self.relay
        r.cfg.cache_bytes = 15000
        for i, key in enumerate(["yt-old0000000", "yt-old1111111", "yt-pin2222222"]):
            with open(r.path(key), "wb") as f:
                f.write(b"x" * 9000)
            r.remember(key, used=int(time.time()) - 10000 + i, source="x", pinned=(key == "yt-pin2222222") or None)
        r.evict()
        left = sorted(os.listdir(r.cfg.cache))
        self.assertIn("yt-pin2222222.mp3", left)
        self.assertNotIn("yt-old0000000.mp3", left)

    def test_meta_survives_restart(self):
        self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/dQw4w9WgXcQ"))
        r2 = rr.Relay(self.relay.cfg)
        self.assertEqual(r2.track("yt-dQw4w9WgXcQ")["title"], "Video dQw4w9WgXcQ")
        r2.pool.shutdown()


    # ------------------------------------------------------------ more features
    def test_direct_audio_links(self):
        url = "https://cdn.example.com/music/Night%20Drive.mp3"
        code, r = self.json("/resolve?q=" + urllib.request.quote(url, safe=""))
        self.assertEqual(code, 200)
        t = r["tracks"][0]
        self.assertTrue(t["key"].startswith("url-"))
        self.assertEqual(t["title"], "Night Drive.mp3")
        self.json("/fetch?key=" + t["key"])
        self.assertEqual(self.wait_ready(t["key"])["state"], "ready")
        code, body, _ = self.get("/a/%s.mp3" % t["key"])
        self.assertEqual((code, len(body)), (200, 4000))
        code, r = self.json("/resolve?q=" + urllib.request.quote("https://cdn.example.com/missing.mp3", safe=""))
        k = r["tracks"][0]["key"]
        self.json("/fetch?key=" + k)
        s = self.wait_ready(k)
        self.assertEqual(s["state"], "error")
        self.assertIn("404", s["error"])

    def test_library_key_resolves_to_itself(self):
        lib = self.relay.cfg.library
        with open(os.path.join(lib, "Song.mp3"), "wb") as f:
            f.write(b"x" * 100)
        code, r = self.json("/library/rescan")
        key = r["tracks"][0]["key"]
        code, r = self.json("/resolve?q=" + key)
        self.assertEqual((code, r["tracks"][0]["key"]), (200, key))
        self.assertEqual(self.json("/resolve?q=lib-doesnotexist00")[0], 400)

    def test_live_and_too_long_are_refused_with_a_reason(self):
        code, r = self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/lllllllllll"))
        self.assertEqual(code, 400)
        self.assertIn("live", r["error"])
        code, r = self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/ggggggggggg"))
        self.assertEqual(code, 400)
        self.assertIn("too long", r["error"])

    def test_empty_query_is_an_error(self):
        code, r = self.json("/resolve?q=")
        self.assertEqual(code, 400)

    def test_a_failed_download_waits_a_minute_before_retrying(self):
        count = os.path.join(self.tmp.name, "count")
        os.environ["FAKE_COUNT"] = count
        try:
            self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/fffffffffff"))
            self.json("/fetch?key=yt-fffffffffff")
            self.wait_ready("yt-fffffffffff")
            for _ in range(3):
                code, s = self.json("/fetch?key=yt-fffffffffff")
                self.assertEqual(s["state"], "error")
            time.sleep(0.3)
            self.assertEqual(len(open(count).read().splitlines()), 1, "no retry inside the minute")
            self.relay.errors["yt-fffffffffff"] = (time.time() - 61, "old")
            self.json("/fetch?key=yt-fffffffffff")
            self.wait_ready("yt-fffffffffff")
            self.assertEqual(len(open(count).read().splitlines()), 2, "retried after it")
        finally:
            os.environ.pop("FAKE_COUNT", None)

    def test_many_listeners_asking_at_once_cause_one_download(self):
        count = os.path.join(self.tmp.name, "count")
        os.environ["FAKE_COUNT"], os.environ["FAKE_SLOW"] = count, "0.5"
        try:
            self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/dQw4w9WgXcQ"))
            threads = [threading.Thread(target=self.json, args=("/fetch?key=yt-dQw4w9WgXcQ",)) for _ in range(8)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertEqual(self.wait_ready("yt-dQw4w9WgXcQ")["state"], "ready")
            self.assertEqual(len(open(count).read().splitlines()), 1)
        finally:
            os.environ.pop("FAKE_COUNT", None)
            os.environ.pop("FAKE_SLOW", None)

    def test_head_and_headers_for_players(self):
        self.json("/resolve?q=" + urllib.request.quote("https://youtu.be/dQw4w9WgXcQ"))
        self.json("/fetch?key=yt-dQw4w9WgXcQ")
        self.wait_ready("yt-dQw4w9WgXcQ")
        req = urllib.request.Request(self.base + "/a/yt-dQw4w9WgXcQ.mp3", method="HEAD")
        with urllib.request.urlopen(req, timeout=10) as r:
            self.assertEqual(r.status, 200)
            self.assertEqual(r.headers["Accept-Ranges"], "bytes")
            self.assertEqual(r.headers["Content-Length"], "9000")
            self.assertIn("max-age", r.headers["Cache-Control"])
            self.assertEqual(r.read(), b"")

    def test_paths_outside_the_prefix_and_unknown_ones(self):
        port = self.httpd.server_address[1]
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen("http://127.0.0.1:%d/other/health" % port, timeout=5)
        self.assertEqual(e.exception.code, 404)
        self.assertEqual(self.json("/nope")[0], 404)


class YoutubeIdsTest(unittest.TestCase):
    def test_parse(self):
        f = rr.youtube_ids
        self.assertEqual(f("https://youtu.be/dQw4w9WgXcQ"), ("dQw4w9WgXcQ", None))
        self.assertEqual(f("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1234567890ab"), ("dQw4w9WgXcQ", "PL1234567890ab"))
        self.assertEqual(f("https://music.youtube.com/playlist?list=OLAK5uy_abcdefghij"), (None, "OLAK5uy_abcdefghij"))
        self.assertEqual(f("https://example.com/watch?v=dQw4w9WgXcQ"), (None, None))
        self.assertEqual(f("https://www.youtube.com/watch?v=bad"), (None, None))


if __name__ == "__main__":
    unittest.main()
