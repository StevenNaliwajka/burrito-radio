"""tests/FEATURES.txt is the feature list; this keeps it honest.

Every line must point at a test that exists, every test must be claimed by a
feature (so a new test means a new line, and nothing is tested that nobody
needs), and the areas the radio is about must all be there."""
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AREAS = {"play", "queue", "library", "perms", "pinned", "sound", "menu", "model", "relay", "ship", "live", "cache", "security", "move"}


def features():
    out = []
    with open(os.path.join(HERE, "FEATURES.txt")) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 4:
                raise AssertionError("FEATURES.txt:%d needs 4 fields: %s" % (n, line))
            out.append((n, *parts))
    return out


def tests_in(fname):
    src = open(os.path.join(HERE, fname)).read()
    if fname.endswith(".lua"):
        return re.findall(r'^test\("((?:[^"\\]|\\.)*)"', src, re.M)
    return re.findall(r"^\s+def (test_\w+)\(", src, re.M)


class FeatureListTest(unittest.TestCase):
    def test_every_feature_names_a_real_test(self):
        for n, area, feat, fname, name in features():
            with self.subTest(line=n, feature=feat):
                self.assertIn(area, AREAS, "unknown area")
                hits = [t for t in tests_in(fname) if name in t]
                self.assertEqual(len(hits), 1, "%s: %r matches %d tests in %s" % (feat, name, len(hits), fname))

    def test_every_test_serves_a_feature(self):
        claimed = {}
        for _, _, _, fname, name in features():
            claimed.setdefault(fname, []).append(name)
        for fname in ("test_radio.lua", "test_client.lua", "test_relay.py", "test_ship.py", "test_live.py"):
            for t in tests_in(fname):
                with self.subTest(test=t):
                    self.assertTrue(any(c in t for c in claimed.get(fname, [])),
                                    "%s: %r is not in FEATURES.txt" % (fname, t))

    def test_every_area_is_covered(self):
        have = {}
        for _, area, *_ in features():
            have[area] = have.get(area, 0) + 1
        for a in AREAS:
            self.assertGreaterEqual(have.get(a, 0), 3, "area %s has %d features" % (a, have.get(a, 0)))


if __name__ == "__main__":
    unittest.main()
