#!/bin/bash
# Build, verify, back up the existing installed app, and replace ~/Applications/PersonalSpace.app.
# Follows the local certificate workflow in scripts/package_release.sh (no notarization or Gatekeeper changes).
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target_dir="$HOME/Applications"
target_app="$target_dir/PersonalSpace.app"
package_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "--target requires an application path." >&2
                exit 2
            fi
            target_app="$2"
            target_dir=$(dirname "$target_app")
            shift 2 ;;
        --help)
            echo "Usage: scripts/install_local.sh [--target /path/to/PersonalSpace.app] [--skip-build] [--identity NAME_OR_SHA1 | --adhoc]"
            echo "Builds and verifies Release via scripts/package_release.sh, backs up the existing app into .build/backups/, and installs to ~/Applications/PersonalSpace.app."
            exit 0 ;;
        *)
            package_args+=("$1")
            shift ;;
    esac
done

cd "$repository"
if [[ ${#package_args[@]} -gt 0 ]]; then
    "$repository/scripts/package_release.sh" "${package_args[@]}"
else
    "$repository/scripts/package_release.sh"
fi

release_app="$repository/.build/DerivedData/Build/Products/Release/PersonalSpace.app"
if [[ ! -d "$release_app" ]]; then
    echo "Release app not found at $release_app" >&2
    exit 3
fi

info="$release_app/Contents/Info.plist"
new_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
new_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")

# Gracefully quit any running PersonalSpace instance before replacing the bundle.
if /usr/bin/pgrep -x PersonalSpace >/dev/null 2>&1; then
    echo "正在退出运行中的 PersonalSpace…"
    /usr/bin/osascript -e 'tell application id "com.liamamilin.PersonalSpace" to quit' >/dev/null 2>&1 || true
    for _ in {1..30}; do
        if ! /usr/bin/pgrep -x PersonalSpace >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 0.2
    done
    if /usr/bin/pgrep -x PersonalSpace >/dev/null 2>&1; then
        echo "PersonalSpace 未能自动退出，请手动退出（⌘Q）后重试。" >&2
        exit 4
    fi
fi

mkdir -p "$target_dir"

if [[ -d "$target_app" ]]; then
    old_info="$target_app/Contents/Info.plist"
    old_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$old_info" 2>/dev/null || echo "unknown")
    old_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$old_info" 2>/dev/null || echo "0")
    timestamp=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
    backup_dir="$repository/.build/backups"
    backup_app="$backup_dir/Before-Install-$old_version-$old_build-$timestamp.app"
    mkdir -p "$backup_dir"
    echo "备份现有应用 ($old_version build $old_build) -> $backup_app"
    /usr/bin/ditto "$target_app" "$backup_app"
    rm -rf -- "$target_app"
fi

echo "安装 Release $new_version ($new_build) -> $target_app"
/usr/bin/ditto "$release_app" "$target_app"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$target_app"
/usr/bin/cmp -s "$release_app/Contents/MacOS/PersonalSpace" "$target_app/Contents/MacOS/PersonalSpace"

echo "安装校验通过：$target_app ($new_version build $new_build)"
/usr/bin/open "$target_app"
