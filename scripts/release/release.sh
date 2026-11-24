#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "Error: .env file not found"
    exit 1
fi

create_changelogs() {
    local notes_file="$1"
    if [ -z "$notes_file" ] || [ ! -f "$notes_file" ]; then
        echo "Usage: release.sh changelog <path-to-notes.txt>"
        exit 1
    fi

    local version_code
    version_code=$(python3 "$SCRIPT_DIR/../pubspec_version.py" --build-number "$PROJECT_ROOT/pubspec.yaml")

    local prompt="Below is a changelog for a cross-platform Flutter app (iOS, Android, macOS, Linux, Windows). Return ONLY the entries relevant to the given platform. Keep the same format (section headers + bullet points). If a section has no relevant entries, omit it entirely. If an entry is not platform-specific, include it. You MUST stay under the character limit. Aggressively drop less important entries and consolidate similar ones to fit. Count your output characters before responding. Output nothing else."
    local notes
    notes=$(cat "$notes_file")

    # CHANGELOG_SUMMARISER names the command that shortens the notes for a
    # store listing; anything that reads them on standard input and writes
    # shorter notes out will do. Unset, the notes are cut to the limit whole
    # line at a time, so a release never waits on a tool being installed.
    local ios_notes android_notes
    if [ -n "${CHANGELOG_SUMMARISER:-}" ]; then
        # shellcheck disable=SC2086
        ios_notes=$(echo "$notes" | $CHANGELOG_SUMMARISER "$prompt Platform: iOS. Max 4000 characters.")
        # shellcheck disable=SC2086
        android_notes=$(echo "$notes" | $CHANGELOG_SUMMARISER "$prompt Platform: Android. Max 500 characters.")
    else
        ios_notes=$(echo "$notes" | head -c 4000)
        android_notes=$(echo "$notes" | head -c 500)
    fi

    local ios_path="$PROJECT_ROOT/ios/fastlane/metadata/en-US/release_notes.txt"
    local android_path="$PROJECT_ROOT/android/fastlane/metadata/android/en-GB/changelogs/${version_code}.txt"

    mkdir -p "$(dirname "$ios_path")" "$(dirname "$android_path")"
    echo "$ios_notes" > "$ios_path"
    echo "$android_notes" > "$android_path"

    local ios_len=${#ios_notes}
    local android_len=${#android_notes}

    echo "iOS changelog (${ios_len}/4000 chars):"
    echo "$ios_notes"
    echo ""
    echo "Android changelog ${version_code}.txt (${android_len}/500 chars):"
    echo "$android_notes"
}

release_android() {
    cd "$PROJECT_ROOT/android"
    fastlane release
    cd "$PROJECT_ROOT"
}

release_ios() {
    cd "$PROJECT_ROOT/ios"
    fastlane deploy_appstore
    cd "$PROJECT_ROOT"
}

clean() {
    cd "$PROJECT_ROOT/android"
    ./gradlew clean 2>/dev/null || true
    cd "$PROJECT_ROOT/ios"
    xcodebuild clean -workspace Runner.xcworkspace -scheme Runner 2>/dev/null || true
    cd "$PROJECT_ROOT"
    flutter clean
}

case "${1:-help}" in
    changelog) create_changelogs "$2" ;;
    android)   release_android ;;
    ios)       release_ios ;;
    all)       release_android && release_ios ;;
    clean)     clean ;;
    help|--help|-h)
        echo "Usage: ./scripts/release/release.sh <command>"
        echo ""
        echo "Commands:"
        echo "  changelog <file>  Generate platform-specific changelogs from a notes file"
        echo "  android           Build and release to Google Play Store"
        echo "  ios               Build and release to App Store"
        echo "  all               Release to both platforms"
        echo "  clean             Clean build artifacts"
        ;;
    *)
        echo "Unknown command: $1"
        exit 1
        ;;
esac
