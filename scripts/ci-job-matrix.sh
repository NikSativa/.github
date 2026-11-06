#!/bin/bash
set -euo pipefail

reports_dir="$1"
swift_package_index_version_count=4

fail() {
    echo "::error::$1" >&2
    exit 1
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
manifest=""
for report in "$reports_dir"/*/; do
    if [ -s "$report/toolchains.txt" ]; then
        toolchains+=$(cat "$report/toolchains.txt")$'\n'
    fi
    if [ -s "$report/manifest.json" ]; then
        manifest=$(cat "$report/manifest.json")
    fi
done
[ -n "$toolchains" ] || fail "No runner reported a release Xcode with a Swift toolchain"
[ -n "$manifest" ] || fail "No release Xcode on the runners can read Package.swift"

toolchains=$(printf '%s' "$toolchains" | sort -V)
newest_installed_swift=$(minor_of "$(tail -n 1 <<< "$toolchains" | cut -d ' ' -f 1)")
tools_swift=$(minor_of "$(jq -r '.toolsVersion._version' <<< "$manifest")")
declared_platforms=$(jq -r '.platforms[]?.platformName' <<< "$manifest")

version_at_least "$newest_installed_swift" "$tools_swift" \
    || fail "The package needs Swift $tools_swift, but the newest release Xcode on the runners provides Swift $newest_installed_swift"

newest_per_minor=$(awk '{ split($1, parts, "."); latest[parts[1] "." parts[2]] = $0 } END { for (minor in latest) print latest[minor] }' <<< "$toolchains" | sort -V)

supported=""
while IFS=' ' read -r version runner xcode; do
    swift=$(minor_of "$version")
    if version_at_least "$swift" "$tools_swift"; then
        supported+="$swift $runner $xcode"$'\n'
    fi
done <<< "$newest_per_minor"
supported=$(printf '%s' "$supported" | tail -n "$swift_package_index_version_count")
read -r newest_swift newest_runner newest_xcode <<< "$(tail -n 1 <<< "$supported")"

jobs=""
tests_assigned=false
for platform in macos ios maccatalyst tvos visionos watchos; do
    if [ -n "$declared_platforms" ] && ! grep -qx "$platform" <<< "$declared_platforms"; then
        continue
    fi

    name=$(display_name "$platform")
    if [ "$platform" = macos ]; then
        while IFS=' ' read -r swift runner xcode; do
            coverage=false
            if [ "$swift" = "$newest_swift" ]; then
                coverage=true
            fi
            jobs+="$name|$swift|$runner|$xcode|test|$coverage"$'\n'
        done <<< "$supported"
        tests_assigned=true
    else
        action=build
        if [ "$tests_assigned" = false ]; then
            action=test
            tests_assigned=true
        fi
        jobs+="$name|$newest_swift|$newest_runner|$newest_xcode|$action|false"$'\n'
    fi
done
[ -n "$jobs" ] || fail "The package declares no Apple platform to test"

printf '%s' "$jobs" | jq -R -s -c '
    split("\n")
    | map(select(length > 0) | split("|") | {platform: .[0], swift: .[1], runner: .[2], xcode: .[3], action: .[4], coverage: (.[5] == "true")})
    | {include: .}'
