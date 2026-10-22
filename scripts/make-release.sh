#!/bin/zsh
set -eu
cd "${0:A:h:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
app="$PWD/build/Clair.app"
[[ -d "$app" ]] || { echo 'Lance scripts/build.sh avant de créer la distribution.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]] || { echo 'Version du paquet incorrecte.' >&2; exit 1; }
codesign --verify --deep --strict "$app"
mkdir -p build/releases work
stage=$(mktemp -d "$PWD/work/dmg.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
# Seul ce dossier de préparation nouvellement créé est supprimé à la sortie.
ditto "$app" "$stage/Clair.app"
ln -s /Applications "$stage/Applications"
printf 'Glisse Clair.app dans Applications.\nApple Silicon. Signature ad hoc, sans notarisation Apple.\nGuide : https://github.com/sergefavy/clair\n' > "$stage/LIRE-MOI.txt"
hdiutil create -volname "Clair $version" -srcfolder "$stage" -format UDZO -ov "build/releases/Clair-$version-arm64.dmg"
hdiutil verify "build/releases/Clair-$version-arm64.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "build/releases/Clair-$version-arm64.zip"
(cd build/releases && shasum -a 256 "Clair-$version-arm64.dmg" "Clair-$version-arm64.zip" > SHA256SUMS.txt)
echo "Distribution : $PWD/build/releases"
