#!/usr/bin/env python3
"""Download every level file from a WeTransfer link (or a direct link).

Unlike tools/fetch_level.sh, which unwraps only the first level in a zip, this
keeps every .gmd/.gmd2/.lvl/.gdr file in the transfer. Files go to OUT_DIR under
their own names. Runs on a CI runner; nothing is committed.

    fetch_transfer_levels.py URL OUT_DIR
"""

import json
import os
import sys
import urllib.parse
import urllib.request
import zipfile

LEVEL_EXTENSIONS = (".gmd", ".gmd2", ".lvl", ".gdr", ".gdr2")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36"}


def open_url(url, data=None, headers=UA):
    req = urllib.request.Request(url, data=data, headers=headers)
    return urllib.request.urlopen(req, timeout=600)


def resolve_wetransfer(url):
    """Return the direct download link for a WeTransfer link, or None."""
    with open_url(url) as response:
        final_url = response.geturl()
    if "downloads/" not in final_url:
        return None
    path = final_url.split("downloads/", 1)[1].split("?", 1)[0]
    transfer_id, security_hash = path.split("/")[0], path.split("/")[-1]
    body = json.dumps({"security_hash": security_hash, "intent": "entire_transfer"}).encode()
    headers = dict(UA, **{"Content-Type": "application/json"})
    api = f"https://wetransfer.com/api/v4/transfers/{transfer_id}/download"
    with open_url(api, data=body, headers=headers) as response:
        return json.loads(response.read()).get("direct_link")


def main(argv):
    url, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    archive = os.path.join(out_dir, "transfer.bin")
    if "we.tl/" in url or "wetransfer.com/" in url:
        direct = resolve_wetransfer(url)
        if not direct:
            print("::error title=wetransfer::no direct link returned")
            return 1
    else:
        direct = url
    with open_url(direct) as response, open(archive, "wb") as handle:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            handle.write(chunk)
    print(f"downloaded {os.path.getsize(archive)} bytes")

    found = []
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as bundle:
            for info in bundle.infolist():
                name = os.path.basename(info.filename)
                if info.is_dir() or not name.lower().endswith(LEVEL_EXTENSIONS):
                    print(f"skipped {info.filename} ({info.file_size} bytes)")
                    continue
                target = os.path.join(out_dir, name)
                with bundle.open(info) as source, open(target, "wb") as handle:
                    handle.write(source.read())
                found.append((name, os.path.getsize(target)))
    else:
        # Not a zip: a single level file, possibly a bare .gmd2.
        found.append(("level", os.path.getsize(archive)))
        os.replace(archive, os.path.join(out_dir, "level"))
    for name, size in found:
        print(f"level {name} {size} bytes")
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
