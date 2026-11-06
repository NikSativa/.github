#!/bin/bash
set -euo pipefail

runner="$1"
package_dir="$2"
report_dir="$3"

fail() {
    echo "::error::$1" >&2
    exit 1
}

release_xcodes() {
    local app
    for app in /Applications/Xcode*.app; do
        [ -d "$app" ] || continue
        realpath "$app"
    done | sort -u | grep -viE 'beta|release_candidate' || true
}

swift_version_of() {
    "$1/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" --version 2>/dev/null \
        | sed -n -E 's/.*Apple Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' \
        | head -n 1
}

toolchains=""
while IFS= read -r xcode; do
    [ -n "$xcode" ] || continue
    version=$(swift_version_of "$xcode")
    if [ -n "$version" ]; then
        toolchains+="$version $runner $xcode"$'\n'
    fi
done < <(release_xcodes)
[ -n "$toolchains" ] || fail "No release Xcode with a Swift toolchain is installed in /Applications on $runner"

mkdir -p "$report_dir"
printf '%s' "$toolchains" | sort -V > "$report_dir/toolchains.txt"
cat "$report_dir/toolchains.txt"

newest_xcode=$(tail -n 1 "$report_dir/toolchains.txt" | cut -d ' ' -f 3-)
if ! DEVELOPER_DIR="$newest_xcode/Contents/Developer" swift package --package-path "$package_dir" dump-package > "$report_dir/manifest.json"; then
    rm -f "$report_dir/manifest.json"
    echo "The newest release Xcode on $runner cannot read Package.swift"
fi
