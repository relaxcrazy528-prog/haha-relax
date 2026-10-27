#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${1:-$repo_dir/build}"
mkdir -p "$build_root"
build_root="$(cd "$build_root" && pwd)"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
swift build --disable-sandbox --package-path "$repo_dir" --scratch-path "$build_root/swiftpm" -c release --product KeepOnline
bin_dir="$(swift build --disable-sandbox --package-path "$repo_dir" --scratch-path "$build_root/swiftpm" -c release --show-bin-path)"
app_path="$build_root/保持在线.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/KeepOnline" "$app_path/Contents/MacOS/KeepOnline"
cp "$repo_dir/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
python3 - "$app_path/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as out:
    plistlib.dump({
        'CFBundleExecutable':'KeepOnline',
        'CFBundleIdentifier':'local.keep-online.mac',
        'CFBundleName':'保持在线',
        'CFBundleDisplayName':'保持在线',
        'CFBundleVersion':'30',
        'CFBundleShortVersionString':'2.0.0',
        'CFBundlePackageType':'APPL',
        'CFBundleIconFile':'AppIcon',
        'LSMinimumSystemVersion':'14.0',
        'LSUIElement':True,
        'NSHighResolutionCapable':True,
        'NSPrincipalClass':'NSApplication'
    },out,sort_keys=False)
PY
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --options runtime --timestamp=none "$app_path"
else
    codesign --force --sign "$identity" --options runtime --timestamp "$app_path"
fi
plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
