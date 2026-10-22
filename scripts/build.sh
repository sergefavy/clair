#!/bin/zsh
set -eu
cd "${0:A:h:h}"
arch="${ARCH:-arm64}"
[[ "$arch" == arm64 ]] || { echo 'Distribution disponible pour arm64 uniquement.' >&2; exit 1; }
swift build --build-system native -c release --product Clair --arch "$arch"
bin_dir=$(swift build --build-system native -c release --arch "$arch" --show-bin-path)
app="$PWD/build/Clair.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Clair" "$app/Contents/MacOS/Clair"
cp Info.plist "$app/Contents/Info.plist"
cp Clair.icns "$app/Contents/Resources/Clair.icns"
/usr/bin/strip -S "$app/Contents/MacOS/Clair"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Application : $app"
