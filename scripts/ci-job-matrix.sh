#!/bin/bash
set -euo pipefail

package_dir="${1:-.}"

fail() {
    echo "::error::$1" >&2
    exit 1
}

installed_xcodes() {
    local app
    for app in /Applications/Xcode*.app; do
        [ -d "$app" ] || continue
        realpath "$app"
    done | sort -u
}

swift_version_of() {
    "$1/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" --version 2>/dev/null \
        | sed -n -E 's/.*Apple Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' \
        | head -n 1
}

minor_of() {
    echo "$1" | cut -d. -f1-2
}

version_at_least() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

display_name() {
    case "$1" in
    macos) echo "macOS" ;;
    ios) echo "iOS" ;;
    maccatalyst) echo "macCatalyst" ;;
    tvos) echo "tvOS" ;;
    visionos) echo "visionOS" ;;
    watchos) echo "watchOS" ;;
    esac
}

toolchains=""
while IFS= read -r xcode; do
    version=$(swift_version_of "$xcode")
    [ -n "$version" ] && toolchains+="$version $xcode"$'\n'
done < <(installed_xcodes)
[ -n "$toolchains" ] || fail "No Xcode with a Swift toolchain is installed in /Applications"

toolchains=$(printf '%s' "$toolchains" | sort -V)
newest=$(tail -n 1 <<< "$toolchains")
newest_swift=$(minor_of "${newest%% *}")
newest_xcode="${newest#* }"

manifest=$(DEVELOPER_DIR="$newest_xcode/Contents/Developer" swift package --package-path "$package_dir" dump-package)
tools_swift=$(minor_of "$(jq -r '.toolsVersion._version' <<< "$manifest")")
declared_platforms=$(jq -r '.platforms[]?.platformName' <<< "$manifest")

version_at_least "$newest_swift" "$tools_swift" \
    || fail "The package needs Swift $tools_swift, but the newest installed Xcode provides Swift $newest_swift"

newest_per_minor=$(awk '{ split($1, parts, "."); latest[parts[1] "." parts[2]] = $0 } END { for (minor in latest) print latest[minor] }' <<< "$toolchains" | sort -V)

jobs=""
tests_assigned=false
for platform in macos ios maccatalyst tvos visionos watchos; do
    if [ -n "$declared_platforms" ] && ! grep -qx "$platform" <<< "$declared_platforms"; then
        continue
    fi

    name=$(display_name "$platform")
    if [ "$platform" = macos ]; then
        while IFS= read -r toolchain; do
            swift=$(minor_of "${toolchain%% *}")
            version_at_least "$swift" "$tools_swift" || continue
            coverage=false
            [ "$swift" = "$newest_swift" ] && coverage=true
            jobs+="$name|$swift|${toolchain#* }|test|$coverage"$'\n'
        done <<< "$newest_per_minor"
        tests_assigned=true
    else
        action=build
        if [ "$tests_assigned" = false ]; then
            action=test
            tests_assigned=true
        fi
        jobs+="$name|$newest_swift|$newest_xcode|$action|false"$'\n'
    fi
done
[ -n "$jobs" ] || fail "The package declares no Apple platform to test"

printf '%s' "$jobs" | jq -R -s -c '
    split("\n")
    | map(select(length > 0) | split("|") | {platform: .[0], swift: .[1], xcode: .[2], action: .[3], coverage: (.[4] == "true")})
    | {include: .}'
