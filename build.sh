#!/usr/bin/env bash
# Build the FrpClient IPA on macOS.
#
#   ./build.sh              # unsigned IPA (install via TrollStore)
#   ./build.sh TEAMID       # signed IPA via automatic signing (development
#                           # export); the team ID is saved to .team-id and
#                           # reused on later runs
#   ./build.sh --unsigned   # force the unsigned path even if a team ID
#                           # was saved before
#
# Steps:
#   1. Check for Xcode (xcodebuild) and Go (>= 1.26, required by frp 0.72).
#   2. Install gomobile if needed.
#   3. gomobile bind -> ios/FrpClient/Frameworks/Frpclib.xcframework
#      (frp v0.72.0 wrapper, rebuilt from source every run).
#   4. xcodebuild archive + export IPA (signed), or a CODE_SIGNING_ALLOWED=NO
#      build + manual Payload zip (unsigned, for TrollStore).
#
# Idempotent: safe to re-run; previous framework and build outputs are
# removed first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
UNSIGNED=0
TEAM_ID=""
if [ -f .team-id ]; then
    TEAM_ID="$(cat .team-id)"
fi
for arg in "$@"; do
    case "$arg" in
        --unsigned) UNSIGNED=1 ;;
        *) TEAM_ID="$arg" ;;
    esac
done
if [ "$UNSIGNED" -eq 0 ] && [ -n "$TEAM_ID" ]; then
    printf '%s' "$TEAM_ID" > .team-id
fi

# ------------------------------------------------------------------- checks
step "Checking platform and tools"
[ "$(uname -s)" = "Darwin" ] || die "This script must run on macOS (it builds an iOS app)."
command -v xcodebuild >/dev/null 2>&1 || die "Xcode not found. Install Xcode from the App Store, open it once to accept the license, then re-run this script."
command -v zip >/dev/null 2>&1 || die "'zip' not found (it ships with macOS)."

# Go >= 1.26 (frp v0.72.0's go.mod requires Go 1.26.0).
go_ok() {
    command -v go >/dev/null 2>&1 || return 1
    local v major minor
    v="$(go version | sed -E 's/.*go([0-9]+)\.([0-9]+).*/\1 \2/')"
    major="${v%% *}"; minor="${v##* }"
    [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 26 ]; }
}
if ! go_ok; then
    if command -v brew >/dev/null 2>&1; then
        step "Installing Go via Homebrew"
        brew install go
        go_ok || die "Go installed but still < 1.26 (got: $(go version 2>/dev/null))."
    else
        die "Go >= 1.26 is required (frp 0.72 needs it) and was not found.
Install it one of these ways, then re-run this script:
  - Homebrew:  brew install go
  - Download:  https://go.dev/dl/ (macOS arm64 .pkg)"
    fi
fi
step "Go: $(go version)"

# gomobile (binds the Go wrapper into an .xcframework).
export PATH="$PATH:$(go env GOPATH)/bin"
if ! command -v gomobile >/dev/null 2>&1; then
    step "Installing gomobile"
    go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20261011034528-197770444867
    # init downloads the mobile toolchain pieces; iOS bind can work without
    # it, so a failure here is a warning, not fatal.
    gomobile init || echo "WARNING: 'gomobile init' failed; continuing (iOS bind may still work)."
fi
step "gomobile: installed at $(command -v gomobile)"

# Newer gomobile requires golang.org/x/mobile in the module graph
# ("go get -tool ..."); ensure the tool dependency exists before binding.
if ! grep -q '^tool golang.org/x/mobile/cmd/gobind' go/go.mod 2>/dev/null; then
    step "Adding golang.org/x/mobile tool dependency (required by gomobile bind)"
    ( cd go && go get -tool golang.org/x/mobile/cmd/gobind@v0.0.0-20261011034528-197770444867 && go mod tidy )
fi

# ------------------------------------------------------- build the framework
step "Building Frpclib.xcframework from frp v0.72.0 (gomobile bind)"
rm -rf ios/FrpClient/Frameworks/Frpclib.xcframework
mkdir -p ios/FrpClient/Frameworks
# gomobile records its local module replacement in Go build information even
# with -trimpath. Bind an isolated module copy from a neutral temporary path.
MOBILE_STAGE="$(mktemp -d /private/tmp/frpclient-mobile.XXXXXX)"
trap 'rm -rf "$MOBILE_STAGE"' EXIT
mkdir -p "$MOBILE_STAGE/go"
cp go/go.mod go/go.sum "$MOBILE_STAGE/go/"
cp -R go/frpclib "$MOBILE_STAGE/go/"
( cd "$MOBILE_STAGE/go" && gomobile bind -trimpath -target=ios,iossimulator -iosversion=15.0 \
    -o "$ROOT/ios/FrpClient/Frameworks/Frpclib.xcframework" frpclient/frpclib )
step "Framework built: ios/FrpClient/Frameworks/Frpclib.xcframework"
du -sh ios/FrpClient/Frameworks/Frpclib.xcframework

# ------------------------------------------------------------------- signing
if [ "$UNSIGNED" -eq 1 ] || [ -z "$TEAM_ID" ]; then
    if [ -z "$TEAM_ID" ]; then
        echo "No team ID given: building an UNSIGNED IPA for TrollStore."
        echo "(Pass your team ID to get a signed IPA instead: ./build.sh TEAMID)"
    else
        echo "Building an UNSIGNED IPA for TrollStore (--unsigned)."
    fi
    step "Building app (CODE_SIGNING_ALLOWED=NO)"
    rm -rf build
    xcodebuild -project ios/FrpClient.xcodeproj \
        -scheme FrpClient -configuration Release \
        -sdk iphoneos -destination "generic/platform=iOS" \
        -derivedDataPath build/DerivedData \
        OTHER_SWIFT_FLAGS="-debug-prefix-map $ROOT=/src/frpclient" \
        OTHER_CFLAGS="-fdebug-prefix-map=$ROOT=/src/frpclient" \
        CODE_SIGNING_ALLOWED=NO build
    APP="build/DerivedData/Build/Products/Release-iphoneos/FrpClient.app"
    [ -d "$APP" ] || die "Build finished but $APP was not produced."
    # Remove Mach-O debugger/object path entries without modifying code bytes.
    xcrun strip -S "$APP/FrpClient"
    step "Packaging IPA"
    mkdir -p build/Payload
    cp -R "$APP" build/Payload/
    ( cd build && zip -qrD FrpClient-unsigned.ipa Payload )
    IPA="build/FrpClient-unsigned.ipa"
else
    step "Building signed IPA (team $TEAM_ID)"
    mkdir -p build
    sed "s/__TEAM_ID__/$TEAM_ID/" ios/ExportOptions.plist.template > build/ExportOptions.plist
    rm -rf build/FrpClient.xcarchive build/ipa
    xcodebuild archive -project ios/FrpClient.xcodeproj \
        -scheme FrpClient -configuration Release \
        -archivePath build/FrpClient.xcarchive
    xcodebuild -exportArchive \
        -archivePath build/FrpClient.xcarchive \
        -exportOptionsPlist build/ExportOptions.plist \
        -exportPath build/ipa
    IPA="build/ipa/FrpClient.ipa"
fi

# ---------------------------------------------------------------------- done
[ -f "$IPA" ] || die "IPA not found at $IPA after export."
step "Done"
echo "IPA:  $ROOT/$IPA"
echo "Size: $(du -h "$IPA" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$IPA" | cut -d' ' -f1)"
echo
echo "Install through your existing TrollStore workflow. Keep the previous IPA as a backup."
echo "Open the app, confirm configuration, and use Save and Connect."
echo "The model API test is shown beside the connection controls."
echo "Background location is optional and does not guarantee continuous execution."
