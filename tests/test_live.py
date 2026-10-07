"""Live check against a REAL server, over RCON. Skipped unless LIVE_HOST is set:

    LIVE_HOST=10.9.1.13 LIVE_PORT=27015 RCON_PASSWORD=... python3 -m unittest tests/test_live.py

Spawns a throwaway radio at the map's origin, plays a real YouTube song through
the relay, pauses/resumes/skips it, and removes the radio. Run it when nobody is
playing (a radio appears for a minute). Never restarts anything."""
import os
import re
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
from hotload import rcon  # noqa: E402

HOST = os.environ.get("LIVE_HOST")
PORT = int(os.environ.get("LIVE_PORT", "27015"))
PW = os.environ.get("RCON_PASSWORD", "")
SONG = os.environ.get("LIVE_SONG", "https://youtu.be/dQw4w9WgXcQ")


def lua(code):
    return rcon(HOST, PORT, PW, "lua_run " + code)


def val(code):
    out = lua('print("VAL<" .. tostring(%s) .. ">")' % code)
    m = re.search(r"^VAL<(.*?)>", out, re.M)   # not the echoed "> print(..." line
    return m.group(1) if m else None


@unittest.skipUnless(HOST, "set LIVE_HOST, LIVE_PORT, RCON_PASSWORD to run against a real server")
class LiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        lua("BRADIO_LIVE_HIB = GetConVarNumber('sv_hibernate_think') RunConsoleCommand('sv_hibernate_think', '1')")
        lua('local tr=util.TraceLine({start=Vector(0,0,600),endpos=Vector(0,0,-5000)}) '
            'local e,st=BRadio.SpawnRadio(tr.HitPos,Angle(0,0,0),nil,{}) BRADIO_LIVE=st')

    @classmethod
    def tearDownClass(cls):
        lua("if BRADIO_LIVE and IsValid(BRADIO_LIVE.ent) then BRADIO_LIVE.ent:Remove() end BRADIO_LIVE=nil")
        lua("RunConsoleCommand('sv_hibernate_think', tostring(BRADIO_LIVE_HIB or 0))")

    def wait_state(self, want, seconds=90):
        end = time.time() + seconds
        while time.time() < end:
            s = val("BRADIO_LIVE and BRADIO_LIVE.state")
            if s == want:
                return
            time.sleep(1)
        self.fail("never reached %s (last %s)" % (want, s))

    def test_1_loaded_and_relay_reachable(self):
        self.assertEqual(val("BRadio and BRadio.Version ~= nil"), "true", "the addon is loaded")
        self.assertEqual(val("scripted_ents.Get('burrito_radio').Category"), "Burrito")
        lua("BRadio.RefreshLibrary()")
        time.sleep(2)
        self.assertEqual(val("BRadio.Relay.Problem"), "nil", "the server reaches the relay")

    def test_2_youtube_plays_through_the_relay(self):
        lua('BRadio.AddQuery(BRADIO_LIVE, nil, "%s", false)' % SONG)
        self.wait_state("playing")
        self.assertGreater(float(val("BRADIO_LIVE.current.duration")), 30)
        base = val("BRadio.Relay.PublicURL()")
        self.assertTrue(base.startswith("https://"), "players download over https")

    def test_3_pause_resume_skip(self):
        lua("BRadio.Commands.pause(nil, BRADIO_LIVE, {})")
        self.assertEqual(val("BRADIO_LIVE.state"), "paused")
        lua("BRadio.Commands.pause(nil, BRADIO_LIVE, {})")
        self.assertEqual(val("BRADIO_LIVE.state"), "playing")
        lua("BRADIO_LIVE.autoplay=false BRadio.Commands.skip(nil, BRADIO_LIVE, {})")
        self.assertEqual(val("BRADIO_LIVE.state"), "idle")


if __name__ == "__main__":
    unittest.main()
