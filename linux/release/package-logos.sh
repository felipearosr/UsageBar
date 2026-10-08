#!/usr/bin/env bash
# Builds the provider logo pack the GNOME extension downloads when the user
# clicks Download (logopack.js), plus its .sha256:
#
#   linux/release/package-logos.sh VERSION OUT_DIR ASSET
#
# The pack is one JSON file, {"format": 1, "version": VERSION, "icons":
# {"<provider>": "<svg>", ...}}, with every icons/ProviderIcon-<provider>.svg
# of the extension. VERSION is resolve-version.sh's version and ASSET its
# logos_asset. Fails when the extension would reject the pack. Prints the
# pack's path.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
version=$1
out=$2
asset=$3
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
extension_dir=$repo/linux/usagebar-gnome/usagebar@felipearosr.github.io

mkdir -p "$out"
out=$(cd "$out" && pwd)
python3 - "$extension_dir/icons" "$version" "$out/$asset" <<'PY'
import json, pathlib, sys
icons_dir, version, path = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
icons = {
    svg.name[len('ProviderIcon-'):-len('.svg')]: svg.read_text(encoding='utf-8')
    for svg in sorted(icons_dir.glob('ProviderIcon-*.svg'))
}
if not icons:
    sys.exit(f'package-logos: no ProviderIcon-*.svg in {icons_dir}')
with open(path, 'w', encoding='utf-8') as f:
    json.dump({'format': 1, 'version': version, 'icons': icons}, f,
              ensure_ascii=False, separators=(',', ':'), sort_keys=True)
    f.write('\n')
PY
# The same check the extension runs on a download.
node --input-type=module - "$extension_dir/logopack.js" "$out/$asset" "$version" <<'JS' \
    || { echo "package-logos: the extension would reject $asset" >&2; exit 1; }
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const [module, pack, version] = process.argv.slice(2);
const {parseLogoPack} = await import(pathToFileURL(module).href);
try {
    parseLogoPack(fs.readFileSync(pack, 'utf8'), version);
} catch (e) {
    console.error(`package-logos: ${e.message}`);
    process.exit(1);
}
JS
"$repo/Scripts/generate_release_checksum.sh" "$out/$asset" > /dev/null
printf '%s\n' "$out/$asset"
