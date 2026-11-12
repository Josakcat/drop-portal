#!/bin/sh
# Makes a Drop Portal release on this Mac. Pushes nothing, posts nothing.
#
#   Scripts/release.sh 1.1.0             bump, date the changelog, commit, tag, export the
#                                        public copy, build the zip from it, write release notes
#   DRY_RUN=1 Scripts/release.sh 1.1.0   only build the zip from this repo's HEAD, change nothing
#
# Droppy offers an Update when the GitHub repository in droplet.json "source"
# has a release tagged vX.Y.Z newer than the installed version. The zip is the
# exact asset its updater looks for: DropPortal.droplet.zip with
# DropPortal.droplet at its root. Attach ONLY that zip to the GitHub release:
# a DropPortal.droplet.zip.sha256 beside it hides the update (GitHub's own asset
# digest gives Droppy the SHA-256). The .sha256 file stays here, for checking.
set -eu

new="${1:-}"
echo "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: Scripts/release.sh X.Y.Z"; exit 1; }
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
droppykit="${DROPPYKIT:-$HOME/Desktop/Private/droppy/droppykit/Scripts/droppykit}"
out="${RELEASE_DIR:-$HOME/Desktop/Private/droppy/release/drop-portal}/$new"
old=$(/usr/bin/python3 -c 'import json; print(json.load(open("droplet.json"))["version"])')

# Higher than the last one, or the same version if it was never tagged (the first release).
/usr/bin/python3 - "$old" "$new" "$(git tag -l "v$new")" <<'EOF'
import sys
old, new, tagged = sys.argv[1], sys.argv[2], sys.argv[3]
o, n = tuple(map(int, old.split("."))), tuple(map(int, new.split(".")))
if n < o or (n == o and tagged):
    sys.exit(f"{new} is not newer than {old}" + (" (already tagged)" if tagged else ""))
EOF

if [ -z "${DRY_RUN:-}" ]; then
    [ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit your changes first"; exit 1; }
    /usr/bin/python3 - "$new" <<'EOF'
import json, re, sys, subprocess
new = sys.argv[1]
d = json.load(open("droplet.json")); d["version"] = new
open("droplet.json", "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
log = open("CHANGELOG.md").read()
m = re.search(r"## \[Unreleased\]\n(.*?)(?=\n## \[|\Z)", log, re.S)
if not m or not m.group(1).strip():
    sys.exit("CHANGELOG.md has nothing under [Unreleased]")
# BSD date is Gregorian whatever the Mac's calendar.
day = subprocess.check_output(["date", "+%Y-%m-%d"], text=True).strip()
log = log.replace("## [Unreleased]", f"## [Unreleased]\n\n## [{new}] - {day}", 1)
open("CHANGELOG.md", "w").write(log)
EOF
    git add droplet.json CHANGELOG.md
    git commit -q -m "Drop Portal $new"
    git tag "v$new"
    echo "committed and tagged v$new"
    # Like Pixpaw: the zip is built from the public copy, so it is exactly the published source.
    "$repo/Scripts/export-public.sh" "Drop Portal $new"
    src="${PUBLIC_DIR:-$HOME/Desktop/Private/droppy/portal-public}"
else
    src="$repo"
fi

# Build from a neutral folder outside iCloud: the binary keeps the path it was built in.
build=/Users/Shared/drop-portal-build
rm -rf "$build" && mkdir -p "$build"
git -C "$src" archive HEAD | tar -x -C "$build"
rm -rf "$build/AGENTS.md" "$build/CLAUDE.md" "$build/.mcp.json" "$build/.cursor"
( cd "$build" && "$droppykit" build >/dev/null && "$droppykit" validate | tail -1 )
bundle="$build/.build/DropPortal.droplet"
built=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$build/droplet.json")
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" = "$built" ] || { echo "bundle version is not $built"; exit 1; }
if grep -a -q "$HOME" "$bundle/Contents/MacOS/DropPortal"; then
    echo "the binary holds your home folder's path; not making a zip"; exit 1
fi

mkdir -p "$out"
rm -f "$out/DropPortal.droplet.zip" "$out/DropPortal.droplet.zip.sha256"
ditto -c -k --norsrc --keepParent "$bundle" "$out/DropPortal.droplet.zip"
unzip -l "$out/DropPortal.droplet.zip" | grep -q ' DropPortal.droplet/Contents/Info.plist$' || { echo "zip has no DropPortal.droplet at its root"; exit 1; }
( cd "$out" && shasum -a 256 DropPortal.droplet.zip > DropPortal.droplet.zip.sha256 )
echo "version $built"
echo "zip     $out/DropPortal.droplet.zip"
echo "sha256  $(cut -d' ' -f1 "$out/DropPortal.droplet.zip.sha256")"
# Release notes: this version's CHANGELOG section plus how to update.
/usr/bin/python3 - "$built" "$build/CHANGELOG.md" "$out/release-notes.md" <<'EOF'
import re, sys
ver, log, dst = sys.argv[1], open(sys.argv[2]).read(), sys.argv[3]
m = re.search(r"## \[" + re.escape(ver) + r"\][^\n]*\n(.*?)(?=\n## \[|\Z)", log, re.S)
body = m.group(1).strip() if m else "(no CHANGELOG section for " + ver + " yet)"
open(dst, "w").write(body + "\n\nTo update: open Drop Portal in Droppy's Settings and click Update.\n")
EOF
echo "notes   $out/release-notes.md"
cat <<EOF

Nothing has left this Mac. When you are ready, each on its own (each needs a yes):
  git -C "${PUBLIC_DIR:-$HOME/Desktop/Private/droppy/portal-public}" push && git -C "${PUBLIC_DIR:-$HOME/Desktop/Private/droppy/portal-public}" push origin v$new
  gh release create v$new "$out/DropPortal.droplet.zip" --repo Josakcat/drop-portal --title "Drop Portal $new" --notes-file "$out/release-notes.md"
EOF
