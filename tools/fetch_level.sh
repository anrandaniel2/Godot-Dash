#!/usr/bin/env bash
# Downloads a maintainer-shared level on a CI runner: fetch_level.sh URL OUT.
# Dropbox/direct links are fetched as-is; WeTransfer links (we.tl or
# wetransfer.com/downloads/ID/HASH) go through the transfer download API.
# A zip wrapping a .gmd2/.gmd is unwrapped; a bare .gmd2 is kept whole.
set -euo pipefail
url="$1"
out="$2"
case "$url" in
	*we.tl/*|*wetransfer.com/*)
		page=$(curl -sIL -m 60 -o /dev/null -w '%{url_effective}' "$url")
		path=${page#*downloads/}
		path=${path%%\?*}
		id=$(echo "$path" | cut -d/ -f1)
		hash=$(echo "$path" | awk -F/ '{print $NF}')
		resp=$(curl -s -m 60 -X POST -H "Content-Type: application/json" \
			-d "{\"security_hash\":\"$hash\",\"intent\":\"entire_transfer\"}" \
			"https://wetransfer.com/api/v4/transfers/$id/download")
		direct=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('direct_link',''))")
		if [ -z "$direct" ]; then
			echo "::warning title=wetransfer::page=$page response=$(echo "$resp" | head -c 300)"
			exit 1
		fi
		curl -sL -m 600 "$direct" -o "$out"
		;;
	*)
		curl -sL -m 120 "$url" -o "$out"
		;;
esac
python3 - "$out" <<'PY'
import sys, zipfile
path = sys.argv[1]
if zipfile.is_zipfile(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        inner = [n for n in names if n.lower().endswith((".gmd2", ".gmd", ".txt"))]
        if inner:
            data = archive.read(inner[0])
            open(path, "wb").write(data)
            print("unwrapped", inner[0], len(data))
PY
echo "::notice title=download::size=$(stat -c %s "$out") type=$(file -b "$out" | cut -c1-60)"
