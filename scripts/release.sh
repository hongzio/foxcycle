#!/bin/sh
# Publishes FoxCycle <version>: tags main, attaches the universal app to a GitHub release and
# updates the cask in the Homebrew tap from packaging/foxcycle.rb.
# Usage: scripts/release.sh 0.1.0
#   TAP_DIR   hongzio/homebrew-tap clone (default: ~/Projects/homebrew-tap)
#
# The app is signed with the local identity from scripts/create-signing-identity.sh, which keeps
# the Accessibility grant valid across upgrades. So releases can only be built on the Mac that
# holds that identity.
set -eu

version=${1:?usage: release.sh <version>}
root=$(cd "$(dirname "$0")/.." && pwd)
tap=${TAP_DIR:-$HOME/Projects/homebrew-tap}
tag="v$version"
zip="$root/build/FoxCycle-$version.zip"

die() {
    echo "release: $*" >&2
    exit 1
}

echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must look like 1.2.3, got '$version'"

cd "$root"
[ "$(git branch --show-current)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes"
git fetch -q origin
git merge-base --is-ancestor origin/main main || die "main is behind origin/main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then die "tag $tag exists"; fi
[ -d "$tap/.git" ] || die "no tap clone at $tap (set TAP_DIR)"
[ -z "$(git -C "$tap" status --porcelain)" ] || die "uncommitted changes in $tap"
git -C "$tap" pull -q --ff-only
gh auth status >/dev/null 2>&1 || die "gh is not logged in"

scripts/test.sh
VERSION=$version BUILD_NUMBER=$version ARCHS="arm64 x86_64" scripts/build-app.sh
for arch in arm64 x86_64; do
    lipo build/FoxCycle.app/Contents/MacOS/FoxCycle -verify_arch "$arch" || die "no $arch in the binary"
done
rm -f "$zip"
ditto -c -k --keepParent build/FoxCycle.app "$zip"
sha=$(shasum -a 256 "$zip" | cut -d ' ' -f 1)

git tag -a "$tag" -m "FoxCycle $version"
git push -q origin main "$tag"
gh release create "$tag" "$zip" --title "FoxCycle $version" --generate-notes

mkdir -p "$tap/Casks"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" packaging/foxcycle.rb >"$tap/Casks/foxcycle.rb"
git -C "$tap" add Casks/foxcycle.rb
git -C "$tap" commit -q -m "foxcycle $version"
git -C "$tap" push -q
echo "released FoxCycle $version"
