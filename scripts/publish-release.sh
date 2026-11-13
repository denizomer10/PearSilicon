#!/bin/bash
# Publishes the committed, pushed HEAD as vX.Y.Z (Latest) plus the companion
# vX.Y.Z-beta prerelease that the updater in 0.7.0 and older looks for.
#
# The updater rejects a download whose embedded PearBuildCommit differs from
# the commit the release tag points to, so this script only ships a ZIP built
# from a clean tree at exactly the tagged commit, and checks the uploaded
# asset afterwards.
#
# Usage: scripts/publish-release.sh <release-notes.md>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTES="${1:?usage: publish-release.sh <release-notes.md>}"
[[ -f "$NOTES" ]] || { echo "error: notes file $NOTES not found" >&2; exit 1; }

VERSION="$(sed -n 's/^APP_VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
BUILD="$(sed -n 's/^APP_BUILD="\(.*\)"$/\1/p' scripts/build-app.sh)"
TAG="v$VERSION"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

fail() { echo "error: $*" >&2; exit 1; }

# --- 1) The tree must be exactly what the tag will point to -----------------
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
  || fail "uncommitted changes; commit them first (the app embeds HEAD)"
git fetch -q origin
HEAD_COMMIT="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" == "$HEAD_COMMIT" ]] \
  || fail "HEAD $HEAD_COMMIT is not pushed to origin/$BRANCH"
if gh release view "$TAG" >/dev/null 2>&1 || git ls-remote --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "$TAG already exists; bump APP_VERSION/APP_BUILD in scripts/build-app.sh"
fi
echo ">> Publishing $TAG (build $BUILD) from $HEAD_COMMIT"

# --- 2) Build -----------------------------------------------------------------
if [[ -x scripts/setup-legacy-engine.sh ]]; then
  scripts/setup-legacy-engine.sh --no-build >/dev/null
fi
scripts/make-zip.sh release
APP="$ROOT/build/PearSilicon.app"
ZIP="$ROOT/build/PearSilicon.zip"

plist() { /usr/bin/plutil -extract "$1" raw "$APP/Contents/Info.plist"; }
[[ "$(plist PearBuildCommit)" == "$HEAD_COMMIT" ]] || fail "built app embeds $(plist PearBuildCommit), not $HEAD_COMMIT"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "built app version mismatch"
[[ "$(plist CFBundleVersion)" == "$BUILD" ]] || fail "built app build number mismatch"
[[ -f "$APP/Contents/Resources/PearLegacyEngine/touchHLE_dylibs/angle/libEGL.dylib" ]] \
  || fail "PearLegacyEngine is bundled without ANGLE; 32-bit games would not start"
for component in libPearOpenGLES.dylib PearANGLE/libEGL.dylib PearANGLE/libGLESv2.dylib; do
  [[ -f "$APP/Contents/Resources/$component" ]] || fail "$component is missing; iOS OpenGL ES games could not be prepared"
  /usr/bin/vtool -show-build "$APP/Contents/Resources/$component" | grep -q "platform MACCATALYST" \
    || fail "$component is not a Mac Catalyst binary"
done
/usr/bin/codesign --verify --deep --strict "$APP"
# Every license text and notice is in the archive, and every commit the
# source pointers name (engine, JIT, ANGLE fork, runtime) is on GitHub.
scripts/verify-licenses.sh --remote "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "the build changed tracked files"

# --- 3) Publish -----------------------------------------------------------------
gh release create "$TAG" "$ZIP" --target "$HEAD_COMMIT" --title "PearSilicon $TAG" \
  --notes-file "$NOTES" --latest
gh release create "$TAG-beta" "$ZIP" --target "$HEAD_COMMIT" --prerelease \
  --title "PearSilicon $VERSION (update channel for 0.7.0 and older)" \
  --notes "Same build as [$TAG](https://github.com/$REPO/releases/tag/$TAG) ($VERSION, build $BUILD). This prerelease lets the updater in 0.7.0 and older, which only looks at prereleases, find $VERSION."

# --- 4) Verify what users will download -----------------------------------------
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
for tag in "$TAG" "$TAG-beta"; do
  tag_commit="$(git ls-remote origin "refs/tags/$tag" | cut -f1)"
  [[ "$tag_commit" == "$HEAD_COMMIT" ]] || fail "$tag points to $tag_commit, not $HEAD_COMMIT"
  digest="$(gh api "repos/$REPO/releases/tags/$tag" -q '.assets[0].digest')"
  [[ "$digest" == "sha256:$SHA" ]] || fail "$tag asset digest $digest != sha256:$SHA"
  mkdir -p "$CHECK/$tag"
  gh release download "$tag" -p PearSilicon.zip -D "$CHECK/$tag" >/dev/null
  ditto -x -k "$CHECK/$tag/PearSilicon.zip" "$CHECK/$tag/x"
  embedded="$(/usr/bin/plutil -extract PearBuildCommit raw "$CHECK/$tag/x/PearSilicon.app/Contents/Info.plist")"
  [[ "$embedded" == "$tag_commit" ]] || fail "$tag: downloaded app embeds $embedded, tag is $tag_commit"
  scripts/verify-licenses.sh "$CHECK/$tag/PearSilicon.zip" || fail "$tag: downloaded archive lacks license notices"
  echo ">> $tag OK: commit $tag_commit, sha256 $SHA"
done
echo ">> Published $TAG and $TAG-beta"
