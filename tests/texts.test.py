"""plugins/ergana/scripts/texts.py and texts.sh, the plugin's message catalogues: every line in
English and in French, every key a script says exists, and no French anywhere else in the plugin
(La3, John, 27 Nov 2026):
  python3 tests/texts.test.py
"""

import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(HERE, "plugins", "ergana")
SCRIPTS = os.path.join(PLUGIN, "scripts")
FRENCH = re.compile("[àâçéèêëîïôûùüÿœÀÂÇÉÈÊËÎÏÔÛÙÜŸŒ«»]")
CATALOGUES = {"texts.py", "texts.sh"}


def messages():
    scope = {}
    path = os.path.join(SCRIPTS, "texts.py")
    with open(path, encoding="utf-8") as f:
        exec(compile(f.read(), path, "exec"), scope)
    return scope["MESSAGES"]


def read(name):
    with open(os.path.join(SCRIPTS, name), encoding="utf-8") as f:
        return f.read()


def shell(key, lang, *values):
    script = '. "$1"; shift; say "$@"'
    return subprocess.run(["sh", "-c", script, "sh", os.path.join(SCRIPTS, "texts.sh"), key, *values],
                          env={**os.environ, "LANG": lang}, capture_output=True, text=True)


class Texts(unittest.TestCase):
    def test_every_python_key_has_both_languages(self):
        for key, lines in messages().items():
            self.assertEqual(set(lines), {"en", "fr"}, key)
            self.assertTrue(lines["en"].strip() and lines["fr"].strip(), key)
            self.assertEqual(lines["en"].count("%"), lines["fr"].count("%"), key)

    def test_every_key_a_python_script_says_exists(self):
        known = messages()
        for name in ("ergana-auth.py", "ergana-hook.py"):
            said = set(re.findall(r'\bsay\("([a-z0-9_.]+)"\)', read(name)))
            self.assertTrue(said, name)
            self.assertEqual(said - set(known), set(), name)

    def test_every_key_a_shell_script_says_has_both_languages(self):
        said = set()
        for name in ("session-context.sh", "stop.sh"):
            said |= set(re.findall(r"^\s*(?:\w+=\$\()?say ([a-z_]+)", read(name), re.M))
        self.assertTrue(said)
        for key in said:
            en, fr = shell(key, "en_US.UTF-8", "x", "y"), shell(key, "fr_FR.UTF-8", "x", "y")
            self.assertEqual((en.returncode, fr.returncode), (0, 0), key)
            self.assertTrue(en.stdout and fr.stdout and en.stdout != fr.stdout, key)

    def test_a_value_is_never_a_format(self):
        self.assertEqual(shell("workspace", "en_US.UTF-8", "%s%d", "x").stdout,
                         "Ergana workspace: %s%d (x)")

    def test_no_french_outside_the_catalogues(self):
        found = []
        for root, _, files in os.walk(PLUGIN):
            for name in files:
                path = os.path.join(root, name)
                if name in CATALOGUES or "__pycache__" in path:
                    continue
                with open(path, encoding="utf-8", errors="replace") as f:
                    for n, line in enumerate(f, 1):
                        if FRENCH.search(line):
                            found.append("%s:%d" % (os.path.relpath(path, HERE), n))
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
