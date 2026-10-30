#!/bin/bash
# Sourced by build_app.sh. Keep release-only gates out of local development.

select_release_signing_identity() {
    local identities candidates count selected
    [[ "$SIGN_IDENTITY" != - ]] || fail "A release requires Developer ID Application signing; ad-hoc signing is forbidden."
    identities="$(security find-identity -v -p codesigning)" || fail "Cannot read signing identities."
    candidates="$(printf '%s\n' "$identities" | sed -nE 's/^[[:space:]]*[[:digit:]]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application:[^"]+)".*$/\1|\2/p')"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        selected="$(printf '%s\n' "$candidates" | awk -F'|' -v requested="$SIGN_IDENTITY" 'tolower($1) == tolower(requested) || $2 == requested')"
    else
        selected="$candidates"
    fi
    count="$(printf '%s\n' "$selected" | awk 'NF { count++ } END { print count+0 }')"
    [[ "$count" == 1 ]] || fail "Select exactly one valid Developer ID Application identity with --sign-identity (found $count)."
    SIGN_IDENTITY="${selected%%|*}"
    RELEASE_IDENTITY_LABEL="${selected#*|}"
    RELEASE_TEAM_ID="${RELEASE_IDENTITY_LABEL##*(}"
    RELEASE_TEAM_ID="${RELEASE_TEAM_ID%)}"
    [[ "$RELEASE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Cannot determine Developer ID team."
    printf 'Release signing certificate: %s (%s)\n' "$RELEASE_IDENTITY_LABEL" "$SIGN_IDENTITY"
}

release_preflight() {
    local command_name source_status source_commit
    [[ -n "$NOTARY_PROFILE" ]] || fail "--release requires --notary-profile (credentials must already be in Keychain)."
    [[ "$MAKE_DMG" == true ]] || fail "--release requires a DMG; --no-dmg is for development."
    [[ -z "$INSTALL_DIR" ]] || fail "--install is for development; install a release from its verified DMG."
    for command_name in security hdiutil spctl file shasum; do
        command -v "$command_name" >/dev/null || fail "Missing release command: $command_name"
    done
    xcrun --find notarytool >/dev/null || fail "Install Xcode notarytool."
    xcrun --find stapler >/dev/null || fail "Install Xcode stapler."
    source_status="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal)" \
        || fail "Cannot inspect release source state."
    [[ -z "$source_status" ]] \
        || fail "Release source must be committed and clean; use a dedicated release worktree."
    source_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)" || fail "Cannot read release source commit."
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    if [[ -n "$NOTARY_KEYCHAIN" ]]; then NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN"); fi
    plutil -lint "$PROJECT_DIR/Resources/XiaoPen.entitlements"
    mkdir -p "$BUILD_DIR/notarization"
    EVIDENCE_DIR="$(mktemp -d "$BUILD_DIR/notarization/$VERSION-$BUILD_NUMBER-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
    printf 'Release evidence: %s\n' "$EVIDENCE_DIR"
    # Validate credentials before an expensive build, without exporting the
    # Keychain item or retaining other projects' notarization history.
    xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json \
        >/dev/null 2>"$EVIDENCE_DIR/credentials-check.log" \
        || fail "Notarization credentials unavailable; see $EVIDENCE_DIR/credentials-check.log."
    {
        printf 'Version: %s (%s)\nIdentity: %s\nSHA-1: %s\nTeam: %s\n' \
            "$VERSION" "$BUILD_NUMBER" "$RELEASE_IDENTITY_LABEL" "$SIGN_IDENTITY" "$RELEASE_TEAM_ID"
        printf 'Source commit: %s\n' "$source_commit"
    } > "$EVIDENCE_DIR/release-summary.txt"
}

release_check() {
    local log_name="$1"
    shift
    if ! "$@" >"$EVIDENCE_DIR/$log_name.log" 2>&1; then
        cat "$EVIDENCE_DIR/$log_name.log" >&2
        fail "Release validation failed: $log_name (evidence: $EVIDENCE_DIR)."
    fi
}

assert_release_signature() {
    local target="$1" needs_runtime="$2" description
    description="$(codesign --display --verbose=4 "$target" 2>&1)" || fail "Cannot inspect signature: $target"
    printf '%s\n' "$description" >> "$EVIDENCE_DIR/signatures.log"
    printf '%s\n' "$description" | /usr/bin/grep -Fqx "Authority=$RELEASE_IDENTITY_LABEL" \
        || fail "Wrong Developer ID authority: $target"
    printf '%s\n' "$description" | /usr/bin/grep -Fqx "TeamIdentifier=$RELEASE_TEAM_ID" \
        || fail "Wrong signing team: $target"
    printf '%s\n' "$description" | /usr/bin/grep -Eq '^Timestamp=.' \
        || fail "Missing secure signing timestamp: $target"
    if [[ "$needs_runtime" == true ]]; then
        printf '%s\n' "$description" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' \
            || fail "Hardened Runtime is missing: $target"
    fi
}

sign_release_app() {
    local target executable_name bundle_plist
    printf 'Signing nested code, then the app, for Developer ID distribution…\n'
    # Depth-first traversal signs any future embedded Mach-O libraries/helpers
    # before their enclosing code bundles. Never use --deep to sign.
    while IFS= read -r -d '' target; do
        if [[ -f "$target" && ! -L "$target" ]]; then
            [[ "$target" != "$MACOS_DIR/$APP_NAME" ]] || continue
            if file -b "$target" | /usr/bin/grep -q 'Mach-O'; then
                codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$target"
                codesign --verify --strict --verbose=2 "$target"
                assert_release_signature "$target" true
            fi
        elif [[ -d "$target" && "$target" != "$STAGED_APP" ]]; then
            case "$target" in
                *.app|*.xpc|*.framework|*.bundle)
                    bundle_plist="$target/Contents/Info.plist"
                    [[ -f "$bundle_plist" ]] || bundle_plist="$target/Resources/Info.plist"
                    [[ -f "$bundle_plist" ]] || continue
                    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle_plist" 2>/dev/null || true)"
                    [[ -n "$executable_name" ]] || continue
                    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$target"
                    codesign --verify --strict --verbose=2 "$target"
                    assert_release_signature "$target" true
                    ;;
            esac
        fi
    done < <(find "$STAGED_APP" -depth -print0)
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/Resources/XiaoPen.entitlements" "$STAGED_APP"
    release_check app-codesign codesign --verify --deep --strict --verbose=4 "$STAGED_APP"
    assert_release_signature "$STAGED_APP" true
    codesign --display --entitlements - --xml "$STAGED_APP" >"$EVIDENCE_DIR/app-entitlements.plist" 2>"$EVIDENCE_DIR/app-entitlements.log"
    release_check app-entitlements-lint plutil -lint "$EVIDENCE_DIR/app-entitlements.plist"
}

notarize_and_staple() {
    local archive="$1" staple_target="$2" label="$3" submission_id status wait_result=0
    printf 'Submitting %s for Apple notarization…\n' "$label"
    # Persist the UUID before waiting: a timeout/interruption must not hide a
    # submission that is still running on Apple's servers.
    if ! xcrun notarytool submit "$archive" "${NOTARY_AUTH[@]}" --no-wait --output-format json \
        >"$EVIDENCE_DIR/$label-submit.json" 2>"$EVIDENCE_DIR/$label-submit.stderr.log"; then
        fail "Apple upload failed for $label; see $EVIDENCE_DIR/$label-submit.stderr.log."
    fi
    submission_id="$(plutil -extract id raw -o - "$EVIDENCE_DIR/$label-submit.json" 2>/dev/null || true)"
    if [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        printf '%s submission: %s\n' "$label" "$submission_id" | tee -a "$EVIDENCE_DIR/release-summary.txt"
    else
        fail "Apple returned no submission ID for $label; see $EVIDENCE_DIR/$label-submit.stderr.log."
    fi
    xcrun notarytool wait "$submission_id" "${NOTARY_AUTH[@]}" --timeout 60m --output-format json \
        >"$EVIDENCE_DIR/$label-wait.json" 2>"$EVIDENCE_DIR/$label-wait.stderr.log" || wait_result=$?
    xcrun notarytool info "$submission_id" "${NOTARY_AUTH[@]}" --output-format json \
        >"$EVIDENCE_DIR/$label-info.json" 2>"$EVIDENCE_DIR/$label-info.stderr.log" \
        || fail "Cannot read Apple submission status; UUID is saved in $EVIDENCE_DIR/$label-submit.json."
    status="$(plutil -extract status raw -o - "$EVIDENCE_DIR/$label-info.json" 2>/dev/null || true)"
    printf '%s status: %s\n' "$label" "$status" | tee -a "$EVIDENCE_DIR/release-summary.txt"
    # Save Apple's rejection diagnostics too. Pending submissions have no log;
    # their durable UUID can be used with notarytool wait/info later.
    if [[ "$status" == Accepted || "$status" == Invalid || "$status" == Rejected ]]; then
        release_check "$label-notary-log-download" xcrun notarytool log "$submission_id" \
            "${NOTARY_AUTH[@]}" "$EVIDENCE_DIR/$label-notary-log.json"
    fi
    [[ "$wait_result" == 0 && "$status" == Accepted ]] \
        || fail "Apple did not accept $label (status: $status); submission ID and diagnostics are in $EVIDENCE_DIR."
    release_check "$label-staple" xcrun stapler staple "$staple_target"
    release_check "$label-stapler-validate" xcrun stapler validate "$staple_target"
}

notarize_release_app() {
    local upload_zip="$STAGING_DIR/$APP_NAME-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$upload_zip"
    notarize_and_staple "$upload_zip" "$STAGED_APP" app
    release_check app-codesign-stapled codesign --verify --deep --strict --verbose=4 "$STAGED_APP"
    release_check app-gatekeeper spctl --assess --type execute --verbose=4 "$STAGED_APP"
    if command -v syspolicy_check >/dev/null; then
        release_check app-syspolicy syspolicy_check distribution "$STAGED_APP"
    fi
}

finish_release_dmg() {
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$STAGED_DMG"
    release_check dmg-codesign codesign --verify --strict --verbose=4 "$STAGED_DMG"
    assert_release_signature "$STAGED_DMG" false
    notarize_and_staple "$STAGED_DMG" "$STAGED_DMG" dmg
    release_check dmg-codesign-stapled codesign --verify --strict --verbose=4 "$STAGED_DMG"
    release_check dmg-gatekeeper spctl --assess --type open --context context:primary-signature --verbose=4 "$STAGED_DMG"
    # Read back the actual app from the final, stapled container. The EXIT trap
    # detaches this mount even if any nested check fails.
    MOUNTED_DMG="$STAGING_DIR/verify-mount"
    mkdir -p "$MOUNTED_DMG"
    release_check dmg-mount hdiutil attach -readonly -nobrowse -mountpoint "$MOUNTED_DMG" "$STAGED_DMG"
    release_check mounted-app-codesign codesign --verify --deep --strict --verbose=4 "$MOUNTED_DMG/$APP_NAME.app"
    assert_release_signature "$MOUNTED_DMG/$APP_NAME.app" true
    release_check mounted-app-stapler xcrun stapler validate "$MOUNTED_DMG/$APP_NAME.app"
    release_check mounted-app-gatekeeper spctl --assess --type execute --verbose=4 "$MOUNTED_DMG/$APP_NAME.app"
    if command -v syspolicy_check >/dev/null; then
        release_check mounted-app-syspolicy syspolicy_check distribution "$MOUNTED_DMG/$APP_NAME.app"
    fi
    hdiutil detach "$MOUNTED_DMG"
    MOUNTED_DMG=""
    release_check dmg-integrity hdiutil verify "$STAGED_DMG"
}
