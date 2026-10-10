#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="XiaoPen"
SPEECH_WORKER_NAME="XiaoPenSpeechWorker"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
PLIST_SOURCE="$PROJECT_DIR/Resources/Info.plist"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.icns"
SKIP_BUILD=false
MAKE_DMG=true
KEEP_APP=false
BIN_DIR=""
INSTALL_DIR=""
SIGN_IDENTITY=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/build_app.sh [options]

Build the Release app and local speech helper, sign them, and create an installer.
By default, only the DMG/ZIP is retained; the temporary .app is cleaned up.

  --skip-build       Package existing app and speech helper Release builds.
  --bin-dir PATH     Use products from PATH (requires --skip-build).
  --keep-app         Also retain build/XiaoPen.app for development.
  --no-dmg           Create only the .app; implies --keep-app.
  --install DIR      Also install into DIR, e.g. /Applications.
                     Existing apps must be backed up or moved first.
  --sign-identity ID Select a signing certificate by SHA-1 hash or full name.
                     Use - to explicitly request ad-hoc signing.
  -h, --help         Show this help.

The active toolchain comes from xcrun / xcode-select; DEVELOPER_DIR is respected.
Signing automatically uses an Apple Development identity only when exactly one
is valid. Otherwise it falls back to ad-hoc with a notice. Certificate signing
keeps codesign's default designated requirement; macOS may ask to use its key.
DMG creation falls back to a ZIP if hdiutil cannot create a disk image.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        --keep-app) KEEP_APP=true; shift ;;
        --no-dmg) MAKE_DMG=false; KEEP_APP=true; shift ;;
        --sign-identity)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a hash, name, or -."
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --bin-dir|--install)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a path."
            if [[ "$1" == --bin-dir ]]; then BIN_DIR="$2"; else INSTALL_DIR="$2"; fi
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1 (use --help)." ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Packaging requires macOS."
[[ -z "$BIN_DIR" || "$SKIP_BUILD" == true ]] || fail "--bin-dir requires --skip-build."
[[ -f "$PLIST_SOURCE" ]] || fail "Missing Info.plist: $PLIST_SOURCE"
[[ -f "$ICON_SOURCE" ]] || fail "Missing app icon: $ICON_SOURCE"
[[ ! -L "$BUILD_DIR" ]] || fail "The build directory must not be a symlink."

for command_name in xcrun ditto plutil codesign; do
    command -v "$command_name" >/dev/null || fail "Missing command: $command_name"
done
plutil -lint "$PLIST_SOURCE"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SOURCE")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_SOURCE")"

check_install_destination() {
    if [[ -n "$INSTALL_DIR" ]]; then
        [[ ! -e "$INSTALL_DIR/$APP_NAME.app" && ! -L "$INSTALL_DIR/$APP_NAME.app" ]] \
            || fail "Already installed: $INSTALL_DIR/$APP_NAME.app. Back it up or move it before using --install."
    fi
}
check_install_destination

select_signing_identity() {
    local identity_listing development_identities development_count identity_label
    if [[ -z "$SIGN_IDENTITY" ]]; then
        if command -v security >/dev/null \
            && identity_listing="$(security find-identity -v -p codesigning 2>&1)"; then
            development_identities="$(printf '%s\n' "$identity_listing" | sed -nE 's/^[[:space:]]*[[:digit:]]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Apple Development:[^"]+)".*$/\1|\2/p')"
            development_count="$(printf '%s\n' "$development_identities" | awk 'NF { count++ } END { print count+0 }')"
            if [[ "$development_count" == 1 ]]; then
                SIGN_IDENTITY="${development_identities%%|*}"
                identity_label="${development_identities#*|}"
                printf 'Selected signing certificate: %s (%s)\n' "$identity_label" "$SIGN_IDENTITY"
            else
                SIGN_IDENTITY="-"
                printf 'Found %s valid Apple Development identities; using ad-hoc signing. Select a certificate explicitly with --sign-identity to retain permissions across rebuilds.\n' "$development_count" >&2
            fi
        else
            SIGN_IDENTITY="-"
            printf 'Could not read signing identities; using ad-hoc signing. Privacy and keychain approvals may repeat after rebuilds.\n' >&2
        fi
    fi
    if [[ "$SIGN_IDENTITY" == - ]]; then
        printf 'Signing: ad-hoc (code identity changes when the executable changes).\n'
    else
        printf 'Signing identity: %s\n' "$SIGN_IDENTITY"
        printf 'macOS may request permission to use the signing key.\n'
    fi
}
select_signing_identity

SWIFT_PATH="$(xcrun --find swift)"
printf 'Toolchain: %s\n' "$SWIFT_PATH"
if [[ "$SKIP_BUILD" == false ]]; then
    printf 'Building %s %s (%s), Release…\n' "$APP_NAME" "$VERSION" "$BUILD_NUMBER"
    "$SWIFT_PATH" build --package-path "$PROJECT_DIR" -c release --product "$APP_NAME"
    "$SWIFT_PATH" build --package-path "$PROJECT_DIR" -c release --product "$SPEECH_WORKER_NAME"
fi
if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$("$SWIFT_PATH" build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
fi
[[ -d "$BIN_DIR" ]] || fail "Build products directory not found: $BIN_DIR"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
[[ -x "$BIN_DIR/$APP_NAME" ]] || fail "Release executable not found: $BIN_DIR/$APP_NAME"
[[ -x "$BIN_DIR/$SPEECH_WORKER_NAME" ]] || fail "Release speech helper not found: $BIN_DIR/$SPEECH_WORKER_NAME"
[[ -d "$BIN_DIR/XiaoPen_XiaoPen.bundle" ]] || fail "SwiftPM resource bundle not found: $BIN_DIR/XiaoPen_XiaoPen.bundle"

# Swift's Xcode build engine compiles the MLX Metal resources. The helper sets
# MLX's explicit library override to Contents/Resources/mlx.metallib before load.
MLX_METAL_LIBRARY=""
for metal_library in \
    "$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
    "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib" \
    "$BIN_DIR/mlx.metallib"; do
    if [[ -s "$metal_library" ]]; then
        MLX_METAL_LIBRARY="$metal_library"
        break
    fi
done
[[ -n "$MLX_METAL_LIBRARY" ]] \
    || fail "MLX Metal library not found in the Release products. Install Xcode's Metal Toolchain and rebuild the speech helper."

mkdir -p "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.xiaopen-package.XXXXXX")"
cleanup_staging() {
    [[ "$STAGING_DIR" == "$BUILD_DIR"/.xiaopen-package.* && ! -L "$STAGING_DIR" ]] || return
    if [[ ! -e "$BUNDLE_DIR" && -d "$STAGING_DIR/previous-$APP_NAME.app" ]]; then
        mv "$STAGING_DIR/previous-$APP_NAME.app" "$BUNDLE_DIR"
    fi
    # find does not follow symlinks, including the DMG's Applications shortcut.
    find "$STAGING_DIR" -depth -delete || printf 'Could not remove staging directory: %s\n' "$STAGING_DIR" >&2
}
trap cleanup_staging EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$BIN_DIR/$SPEECH_WORKER_NAME" "$MACOS_DIR/$SPEECH_WORKER_NAME"
chmod +x "$MACOS_DIR/$SPEECH_WORKER_NAME"
cp "$MLX_METAL_LIBRARY" "$RESOURCES_DIR/mlx.metallib"
cp "$PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"

# The generated Swiftbuild resource accessor checks Bundle.main.resourceURL.
# Bundle.module therefore needs the SwiftPM bundles inside Contents/Resources.
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    ditto "$resource_bundle" "$RESOURCES_DIR/$(basename "$resource_bundle")"
done
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

printf 'Signing and verifying the local app…\n'
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$MACOS_DIR/$SPEECH_WORKER_NAME"
codesign --verify --strict --verbose=2 "$MACOS_DIR/$SPEECH_WORKER_NAME"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
codesign --display -r- "$STAGED_APP"
plutil -lint "$CONTENTS_DIR/Info.plist"

# Keep a persistent .app only when explicitly requested for development.
if [[ "$KEEP_APP" == true ]]; then
    KEPT_APP="$STAGING_DIR/kept-$APP_NAME.app"
    ditto "$STAGED_APP" "$KEPT_APP"
    if [[ -e "$BUNDLE_DIR" || -L "$BUNDLE_DIR" ]]; then
        mv "$BUNDLE_DIR" "$STAGING_DIR/previous-$APP_NAME.app"
    fi
    mv "$KEPT_APP" "$BUNDLE_DIR"
    printf 'App: %s\n' "$BUNDLE_DIR"
fi

if [[ "$MAKE_DMG" == true ]]; then
    DMG_STAGING_DIR="$STAGING_DIR/dmg"
    mkdir -p "$DMG_STAGING_DIR"
    ditto "$STAGED_APP" "$DMG_STAGING_DIR/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGING_DIR/Applications"
    STAGED_DMG="$STAGING_DIR/$APP_NAME-$VERSION.dmg"
    if command -v hdiutil >/dev/null \
        && hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -format UDZO "$STAGED_DMG" \
        && hdiutil verify "$STAGED_DMG"; then
        mv -f "$STAGED_DMG" "$BUILD_DIR/$APP_NAME-$VERSION.dmg"
        printf 'Installer: %s\n' "$BUILD_DIR/$APP_NAME-$VERSION.dmg"
    else
        printf 'DMG creation failed; creating a ZIP installer instead.\n' >&2
        STAGED_ZIP="$STAGING_DIR/$APP_NAME-$VERSION.zip"
        ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$STAGED_ZIP"
        mv -f "$STAGED_ZIP" "$BUILD_DIR/$APP_NAME-$VERSION.zip"
        printf 'Installer: %s\n' "$BUILD_DIR/$APP_NAME-$VERSION.zip"
    fi
fi

if [[ -n "$INSTALL_DIR" ]]; then
    check_install_destination
    mkdir -p "$INSTALL_DIR"
    ditto "$STAGED_APP" "$INSTALL_DIR/$APP_NAME.app"
    codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR/$APP_NAME.app"
    printf 'Installed: %s\n' "$INSTALL_DIR/$APP_NAME.app"
fi
