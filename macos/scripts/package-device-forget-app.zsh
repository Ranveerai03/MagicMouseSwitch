#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
macos_directory=${script_directory:h}
configuration=${1:-debug}
signing_identity=${DEVICE_FORGET_SIGNING_IDENTITY:-}

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    print -u2 "usage: DEVICE_FORGET_SIGNING_IDENTITY='<identity>' $0 [debug|release]"
    exit 64
fi

if [[ -z "$signing_identity" ]]; then
    print -u2 "DEVICE_FORGET_SIGNING_IDENTITY must name a valid Apple Development code-signing identity."
    exit 65
fi

if [[ "$signing_identity" == "-" ]]; then
    print -u2 "Ad-hoc signing is not allowed because it does not provide a durable TCC identity."
    exit 65
fi

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -- "$signing_identity" >/dev/null; then
    print -u2 "The requested code-signing identity is not installed or valid: $signing_identity"
    exit 66
fi

cd "$macos_directory"
/usr/bin/swift build -c "$configuration" -Xswiftc -warnings-as-errors

binary_directory=$(/usr/bin/swift build -c "$configuration" --show-bin-path)
source_binary="$binary_directory/DeviceForget"
app_directory="$macos_directory/.build/$configuration/DeviceForget.app"
contents_directory="$app_directory/Contents"
executable_directory="$contents_directory/MacOS"

if [[ ! -x "$source_binary" ]]; then
    print -u2 "Built DeviceForget executable was not found: $source_binary"
    exit 67
fi

/bin/rm -rf "$app_directory"
/bin/mkdir -p "$executable_directory"
/bin/cp "$source_binary" "$executable_directory/DeviceForget"
/bin/cp "$macos_directory/DeviceForgetApp/Info.plist" "$contents_directory/Info.plist"
/usr/bin/plutil -lint "$contents_directory/Info.plist"

/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    --options runtime \
    "$app_directory"

/usr/bin/codesign --verify --strict --verbose=2 "$app_directory"
/usr/bin/codesign -dv --verbose=4 "$app_directory"
/usr/bin/codesign -dr - "$app_directory"

print "Signed DeviceForget app: $app_directory"
print "Add that .app to Privacy & Security → Accessibility."
print "Run its command-line executable with:"
print "$executable_directory/DeviceForget --address <bluetooth-address>"
