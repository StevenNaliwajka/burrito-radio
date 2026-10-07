"""What gets shipped: the addon sends every client file to players, the
scripts parse, the services are boxed in, the preview renders."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "lua")


def read(*p):
    return open(os.path.join(ROOT, *p)).read()


class ShipTest(unittest.TestCase):
    def test_every_client_file_is_sent_to_players_and_loaded(self):
        auto = read("lua", "autorun", "burrito_radio.lua")
        sent = set(re.findall(r'AddCSLuaFile\(D \.\. "([\w.]+)"\)', auto))
        included = set(re.findall(r'include\(D \.\. "([\w.]+)"\)', auto))
        for f in os.listdir(os.path.join(LUA, "burrito_radio")):
            with self.subTest(file=f):
                self.assertIn(f, included, "never loaded")
                if f.startswith(("cl_", "sh_")):
                    self.assertIn(f, sent, "players would never get it")
                else:
                    self.assertNotIn(f, sent, "server code must not be sent to players")
        init = read("lua", "entities", "burrito_radio", "init.lua")
        for f in ("shared.lua", "cl_init.lua"):
            self.assertIn('AddCSLuaFile("%s")' % f, init)

    def test_addon_json_ships_lua_only(self):
        a = json.loads(read("addon.json"))
        self.assertIn("Burrito", a["title"])
        for pat in ("relay/*", "tests/*", "tools/*", "*.py", "*.sh"):
            self.assertIn(pat, a["ignore"])

    def test_scripts_parse(self):
        for s in ("relay/setup.sh", "relay/update-tools.sh", "tools/deploy.sh", "tests/run.sh", "tools/syntax-check.sh"):
            with self.subTest(script=s):
                r = subprocess.run(["bash", "-n", os.path.join(ROOT, s)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(os.access(os.path.join(ROOT, s), os.X_OK), "not executable")

    def test_relay_service_is_boxed_in(self):
        unit = read("relay", "naliwajka-radio.service")
        for line in ("User=radio", "NoNewPrivileges=true", "ProtectSystem=strict", "ReadWritePaths=/var/lib/naliwajka-radio",
                     "MemoryMax=", "Restart=always"):
            self.assertIn(line, unit)
        timer = read("relay", "naliwajka-radio-update.timer")
        self.assertIn("OnCalendar=", timer, "yt-dlp updates on a schedule")

    def test_relay_setup_never_overwrites_the_owners_config(self):
        setup = read("relay", "setup.sh")
        self.assertRegex(setup, r'if \[ ! -f "\$ETC/relay.env" \]', "relay.env is written once")

    def test_deploy_updates_in_place_so_autorefresh_reaches_players(self):
        d = read("tools", "deploy.sh")
        self.assertIn("stage=$GM/../.burrito_radio.stage", d, "staged outside addons/")
        self.assertIn('cmp -s', d, "only changed files are rewritten")
        self.assertIn('cp -p \\"\\$f\\" \\"\\$dst/\\$f\\"', d, "copied over the live file in place")
        self.assertNotRegex(d, r"mv [^\n]*addons/burrito_radio", "a folder swap hides changes from autorefresh")
        self.assertNotRegex(d, r"systemctl (restart|stop) gmod", "deploy must never restart a game server")
        self.assertIn("rm -rf $GM/addons/naliwajka_radio", d, "the old addon name is cleaned up")

    @unittest.skipUnless(shutil.which("docker") or shutil.which("lua5.1"), "needs Lua 5.1")
    def test_preview_renders(self):
        try:
            import numpy  # noqa: F401
            import PIL  # noqa: F401
        except ImportError:
            self.skipTest("numpy/PIL")
        with tempfile.TemporaryDirectory() as t:
            if shutil.which("lua5.1"):
                cmd = ["lua5.1", "tools/preview/export.lua"]
            else:
                cmd = ["docker", "run", "--rm", "-v", ROOT + ":/w:ro", "-w", "/w", "nickblah/lua:5.1-luarocks-alpine",
                       "lua", "tools/preview/export.lua"]
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(os.path.join(t, "m.json"), "w") as f:
                f.write(r.stdout)
            r = subprocess.run(["python3", "tools/preview/render.py", os.path.join(t, "m.json"), t, "--size", "160"],
                               cwd=ROOT, capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stderr)
            for v in ("front", "back", "side", "three_quarter", "sheet"):
                self.assertTrue(os.path.getsize(os.path.join(t, v + ".png")) > 1000, v)


if __name__ == "__main__":
    unittest.main()
