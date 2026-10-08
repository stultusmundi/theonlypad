#!/bin/sh
# Build a local development bundle. This does not publish or notarize anything.
set -eu
cd "$(dirname "$0")/.."

case "${1:-}" in
    ""|--ad-hoc-sign) ;;
    *) echo "Usage: scripts/package.sh [--ad-hoc-sign]" >&2; exit 2 ;;
esac

mkdir -p dist .cache/packaging
stage=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

scripts/swift.sh package dump-package > "$stage/package.json"
cat Sources/PadCore/AppIdentity.swift > "$stage/metadata.swift"
cat >> "$stage/metadata.swift" <<'SWIFT'

import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("package.json"))) as! [String: Any]
let platforms = manifest["platforms"] as! [[String: Any]]
guard let minimum = platforms.first(where: { $0["platformName"] as? String == "macos" })?["version"] as? String else {
    fatalError("The package must declare its minimum macOS version")
}
let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
guard !AppIdentity.name.isEmpty, !AppIdentity.name.hasPrefix("."),
      AppIdentity.name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
      AppIdentity.version.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
    fatalError("Application name and version must be safe artifact path components")
}
let numericVersion = String(AppIdentity.version.split(separator: "-", maxSplits: 1)[0])
let info: [String: Any] = [
    "CFBundleName": AppIdentity.name,
    "CFBundleDisplayName": AppIdentity.name,
    "CFBundleExecutable": AppIdentity.name,
    "CFBundleIdentifier": AppIdentity.bundleIdentifier,
    "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon",
    "CFBundleShortVersionString": numericVersion,
    "CFBundleVersion": numericVersion,
    "CFBundleGetInfoString": "\(AppIdentity.name) \(AppIdentity.version)",
    "DevelopmentVersion": AppIdentity.version,
    "LSMinimumSystemVersion": minimum,
    "NSHighResolutionCapable": true,
    "NSPrincipalClass": "PadCommandApplication",
    "CFBundleURLTypes": [["CFBundleURLName": AppIdentity.bundleIdentifier + ".open", "CFBundleURLSchemes": [AppIdentity.urlScheme]]],
    "NSHumanReadableCopyright": "MIT license; see Resources/LICENSE.txt",
    "CFBundleDocumentTypes": [[
        "CFBundleTypeName": "Text Document",
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.plain-text", "public.source-code", "public.text"]
    ]]
]
let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
try data.write(to: directory.appendingPathComponent("Info.plist"))
SWIFT
xcrun swift -module-cache-path "$PWD/.cache/packaging" "$stage/metadata.swift" "$stage"
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$stage/Info.plist")
app_version=$(/usr/libexec/PlistBuddy -c 'Print :DevelopmentVersion' "$stage/Info.plist")

helper_name=PadSearchWorker
scripts/swift.sh build --configuration release --product "$app_name"
scripts/swift.sh build --configuration release --product "$helper_name"
bin_path=$(scripts/swift.sh build --configuration release --show-bin-path)
for product in "$app_name" "$helper_name"; do
    if [ ! -f "$bin_path/$product" ] || [ -L "$bin_path/$product" ] || [ ! -s "$bin_path/$product" ] || [ ! -x "$bin_path/$product" ]; then
        printf 'Missing regular executable product: %s\n' "$product" >&2
        exit 1
    fi
done
bundle="$stage/$app_name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers"
cp "$bin_path/$app_name" "$bundle/Contents/MacOS/$app_name"
cp "$bin_path/$helper_name" "$bundle/Contents/Helpers/$helper_name"
chmod 755 "$bundle/Contents/Helpers/$helper_name"
# Remove linker debug-map paths from the distributable copy before signing.
# The original build output remains available for local diagnostics.
/usr/bin/strip -S "$bundle/Contents/MacOS/$app_name"
/usr/bin/strip -S "$bundle/Contents/Helpers/$helper_name"
cp "$stage/Info.plist" "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp docs/third-party-notices.md "$bundle/Contents/Resources/ThirdPartyNotices.md"
xcrun swift -module-cache-path "$PWD/.cache/packaging" scripts/make-icon.swift "$stage/AppIcon.iconset"
iconutil --convert icns --output "$bundle/Contents/Resources/AppIcon.icns" "$stage/AppIcon.iconset"
plutil -lint "$bundle/Contents/Info.plist"

if [ "${1:-}" = "--ad-hoc-sign" ]; then
    codesign --force --sign - "$bundle/Contents/Helpers/$helper_name"
    codesign --force --sign - "$bundle"
    codesign --verify --strict "$bundle/Contents/Helpers/$helper_name"
    codesign --verify --strict "$bundle"
fi

artifact="$PWD/dist/$app_name.app"
archive="$PWD/dist/$app_name-$app_version-$(uname -m).zip"
# Omit Finder/resource-fork metadata from the distributable archive.
ditto -c -k --norsrc --noextattr --keepParent "$bundle" "$stage/$(basename "$archive")"
python3 scripts/sbom.py "$bundle" "$stage/$app_name.sbom.json" "$stage/package.json"
python3 scripts/check-package.py "$bundle" "$stage/$(basename "$archive")" "$stage/$app_name.sbom.json"
python3 scripts/promote-package.py "$stage" "$PWD/dist" "$app_name.app" "$(basename "$archive")" "$app_name.sbom.json"
printf 'Application: %s\nArchive: %s\n' "$artifact" "$archive"
