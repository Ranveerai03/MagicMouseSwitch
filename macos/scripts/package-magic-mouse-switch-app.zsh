#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
macos_directory=${script_directory:h}
configuration=${1:-debug}
signing_identity=${MAGIC_MOUSE_SWITCH_SIGNING_IDENTITY:-Apple Development: Ranveer Rai (U2Q8N3BUGC)}

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    print -u2 "usage: MAGIC_MOUSE_SWITCH_SIGNING_IDENTITY='<Apple Development identity>' $0 [debug|release]"
    exit 64
fi

if [[ "$signing_identity" == "-" ]]; then
    print -u2 "Ad-hoc signing is not allowed for MagicMouseSwitchMac.app."
    exit 65
fi

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -- "$signing_identity" >/dev/null; then
    print -u2 "The requested code-signing identity is not installed or valid: $signing_identity"
    exit 66
fi

cd "$macos_directory"
/usr/bin/swift build -c "$configuration" --disable-sandbox -Xswiftc -warnings-as-errors
binary_directory=$(/usr/bin/swift build -c "$configuration" --disable-sandbox --show-bin-path)
source_binary="$binary_directory/MagicMouseSwitchMac"
app_directory="$macos_directory/.build/$configuration/MagicMouseSwitchMac.app"
contents_directory="$app_directory/Contents"
executable_directory="$contents_directory/MacOS"
resources_directory="$contents_directory/Resources"
icon_source="$macos_directory/../MagicMouseSwitch.Tray/Assets/MagicMouseSwitch.ico"

if [[ ! -x "$source_binary" ]]; then
    print -u2 "MagicMouseSwitchMac executable was not found: $source_binary"
    exit 67
fi

if [[ ! -f "$icon_source" ]]; then
    print -u2 "Magic Mouse Switch icon was not found: $icon_source"
    exit 68
fi

/bin/rm -rf "$app_directory"
/bin/mkdir -p "$executable_directory" "$resources_directory"
/bin/cp "$source_binary" "$executable_directory/MagicMouseSwitchMac"
/bin/cp "$macos_directory/MagicMouseSwitchMacApp/Info.plist" "$contents_directory/Info.plist"
/usr/bin/sips -s format icns "$icon_source" --out "$resources_directory/MagicMouseSwitch.icns" >/dev/null
/usr/bin/plutil -lint "$contents_directory/Info.plist"
/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    --options runtime \
    "$app_directory"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_directory"

print "Packaged and signed Magic Mouse Switch: $app_directory"
