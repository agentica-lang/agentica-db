"""Fetches the SQLite amalgamation that native/sqlite_static.c pins into a new folder OUT.

Usage: python3 -I tools/sqlite_amalgamation.py OUT

The zip is checked against the SHA3-256 that sqlite.org publishes (the pin in native/sqlite_static.c), then only
sqlite3.c and sqlite3.h are written to OUT, which must not exist. Prints the SQLite version.
"""

import hashlib
import io
import pathlib
import re
import sys
import urllib.request
import zipfile

PIN = pathlib.Path(__file__).resolve().parent.parent / "native" / "sqlite_static.c"
MAX_ZIP = 16 * 1024 * 1024
MEMBERS = ("sqlite3.c", "sqlite3.h")


def pinned(name: str) -> str:
    found = re.search(rf'^#define {name} "([^"]+)"$', PIN.read_text(), re.MULTILINE)
    if not found:
        sys.exit(f"{PIN}: no {name}")
    return found.group(1)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1])
    url = pinned("DB_SQLITE_AMALGAMATION_URL")
    digest = pinned("DB_SQLITE_AMALGAMATION_SHA3_256")
    if not url.startswith("https://sqlite.org/"):
        sys.exit(f"not a sqlite.org https url: {url}")
    with urllib.request.urlopen(url, timeout=60) as answer:
        data = answer.read(MAX_ZIP + 1)
    if len(data) > MAX_ZIP:
        sys.exit(f"{url}: more than {MAX_ZIP} bytes")
    got = hashlib.sha3_256(data).hexdigest()
    if got != digest:
        sys.exit(f"{url}: SHA3-256 {got}, pinned {digest}")
    folder = url.rsplit("/", 1)[1].removesuffix(".zip")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        files = {name: archive.read(f"{folder}/{name}") for name in MEMBERS}
    version = re.search(rb'^#define SQLITE_VERSION +"([0-9.]+)"', files["sqlite3.h"], re.MULTILINE)
    if not version:
        sys.exit(f"{url}: sqlite3.h has no SQLITE_VERSION line")
    out.mkdir(parents=True)
    for name, content in files.items():
        (out / name).write_bytes(content)
    print(version.group(1).decode())


if __name__ == "__main__":
    main()
