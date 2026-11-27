#!/usr/bin/env python3
"""Assemble site/index.html: one file with the icon, photograph and the
source zip inlined, so it works wherever it is hosted (including inside an
embed, where a file beside the page cannot be reached).

    python3 site/build.py [--repo https://github.com/OWNER/REPO]
"""
import base64, pathlib, subprocess, sys

here = pathlib.Path(__file__).parent
EMAIL = "opticensus@opticell-limited.com"
SOURCE = "opticensus-0.1.0-src.zip"
repo = sys.argv[sys.argv.index("--repo") + 1] if "--repo" in sys.argv else ""

# The download: the committed source, without the internal notes.
subprocess.run(["git", "archive", "--format=zip", "--prefix=opticensus-0.1.0/", "-o", str(here / SOURCE), "HEAD",
                "Package.swift", "README.md", "LICENSE", "Sources", "Tests"], cwd=here.parent, check=True)

def b64(path):
    return base64.b64encode(path.read_bytes()).decode()

page = (here / "src" / "index.src.html").read_text()
for key, value in {"ICON": b64(here / "assets" / "icon-192.png"), "DESK": b64(here / "assets" / "desk-clean.jpg"),
                   "ZIP": b64(here / SOURCE), "EMAIL": EMAIL, "REPO": repo, "SOURCE": SOURCE}.items():
    page = page.replace("{{" + key + "}}", value)
assert "{{" not in page, "an unfilled placeholder is left"
(here / "index.html").write_text(page)
print(f"site/index.html  {len(page) // 1024} KB, with {SOURCE} ({(here / SOURCE).stat().st_size // 1024} KB, from the last commit) inside")
