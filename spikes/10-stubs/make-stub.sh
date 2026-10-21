#!/bin/sh
# make-stub.sh <stub binary> <dest dir> <app name> <vm> <plugin> <hue>: one generated per-app-per-VM stub.
set -e
bin=$1 dest=$2 name=$3 vm=$4 plugin=$5 hue=$6
app="$dest/$name — $vm.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/stub"
tmp=$(mktemp -d); mkdir "$tmp/i.iconset"
./icon "$hue" "$tmp/1024.png"
for s in 16 32 128 256 512; do sips -z $s $s "$tmp/1024.png" --out "$tmp/i.iconset/icon_${s}x${s}.png" >/dev/null; d=$((s*2)); sips -z $d $d "$tmp/1024.png" --out "$tmp/i.iconset/icon_${s}x${s}@2x.png" >/dev/null; done
iconutil -c icns "$tmp/i.iconset" -o "$app/Contents/Resources/AppIcon.icns"; rm -rf "$tmp"
cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>stub</string>
<key>CFBundleIdentifier</key><string>io.github.lordversa.v2mac.sandbox.$vm.$plugin</string>
<key>CFBundleName</key><string>$name — $vm</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PL
codesign -s - -f "$app" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
