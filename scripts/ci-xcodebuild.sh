#!/bin/bash
set -euo pipefail

action="$1"
platform="$2"
package_dir="${3:-.}"

fail() {
    echo "::error::$1" >&2
    exit 1
}

package_scheme() {
    xcodebuild -list -json | jq -r '
        .workspace.name as $name
        | .workspace.schemes as $schemes
        | if any($schemes[]; . == $name + "-Package") then $name + "-Package"
          elif any($schemes[]; . == $name) then $name
          else $schemes[0] end'
}

generic_destination() {
    case "$1" in
    iOS) echo "generic/platform=iOS Simulator" ;;
    tvOS) echo "generic/platform=tvOS Simulator" ;;
    watchOS) echo "generic/platform=watchOS Simulator" ;;
    visionOS) echo "generic/platform=visionOS Simulator" ;;
    macCatalyst) echo "generic/platform=macOS,variant=Mac Catalyst" ;;
    *) fail "Unsupported platform: $1" ;;
    esac
}

simulator_destination() {
    local runtime_platform="$1" sdk="$2" sdk_version runtimes udid
    sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
    runtimes=$(xcrun simctl list runtimes available -j | jq -c --arg platform "$runtime_platform" --arg sdk "$sdk_version" '
        def version: split(".") | map(tonumber);
        [.runtimes[] | select(.platform == $platform and .isAvailable and ((.version | version) <= ($sdk | version)))]
        | sort_by(.version | version) | reverse | map(.identifier)')
    [ "$runtimes" != "[]" ] \
        || fail "No $platform simulator runtime up to $sdk_version is installed. Install one with: xcodebuild -downloadPlatform $platform"

    udid=$(xcrun simctl list devices available -j | jq -r --argjson runtimes "$runtimes" '
        .devices as $devices
        | [$runtimes[] | ($devices[.] // [])[] | select(.isAvailable) | .udid] | first // empty')
    [ -n "$udid" ] \
        || fail "No $platform simulator device exists for the installed runtimes $runtimes. Create one with: xcrun simctl create <name> <device type> <runtime>"

    echo "id=$udid"
}

test_destination() {
    case "$1" in
    iOS) simulator_destination iOS iphonesimulator ;;
    tvOS) simulator_destination tvOS appletvsimulator ;;
    watchOS) simulator_destination watchOS watchsimulator ;;
    visionOS) simulator_destination xrOS xrsimulator ;;
    macCatalyst) echo "platform=macOS,variant=Mac Catalyst" ;;
    *) fail "Unsupported platform: $1" ;;
    esac
}

cd "$package_dir"
scheme=$(package_scheme)

case "$action" in
build)
    destination=$(generic_destination "$platform")
    xcodebuild build-for-testing \
        -scheme "$scheme" \
        -destination "$destination" \
        -skipMacroValidation \
        -skipPackagePluginValidation
    ;;
test)
    destination=$(test_destination "$platform")
    xcodebuild test \
        -scheme "$scheme" \
        -destination "$destination" \
        -collect-test-diagnostics never \
        -skipMacroValidation \
        -skipPackagePluginValidation
    ;;
*)
    fail "Unsupported action: $action"
    ;;
esac
