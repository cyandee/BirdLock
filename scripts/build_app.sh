#!/bin/zsh
# 构建 BirdLock.app（Release），输出到 dist/BirdLock.app
# 用法：zsh scripts/build_app.sh
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
EXPECTED_VERSION="$(<VERSION)"
VERSION="${VERSION:-$EXPECTED_VERSION}"
[ "$VERSION" = "$EXPECTED_VERSION" ] || { echo "打包版本与 VERSION 不一致" >&2; exit 1; }
python3 -I scripts/fetch_aircraft_model.py
python3 -I scripts/verify_bundle.py --aircraft-resources SharedResources/AircraftModels

# UNIVERSAL=1 builds for Apple silicon and Intel (needed when distributing to other Macs)
ARCH_ARGS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_ARGS=(--arch arm64 --arch x86_64)
swift build -c release --product BirdLock "${ARCH_ARGS[@]}"
swift build -c release --product BirdLockInterpolation "${ARCH_ARGS[@]}"
BIN="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)/BirdLock"

APP="${APP_OUTPUT:-$ROOT/dist/BirdLock.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Models"
cp "$BIN" "$APP/Contents/MacOS/BirdLock"
cp "${BIN:h}/BirdLockInterpolation" "$APP/Contents/MacOS/BirdLockInterpolation"
chmod 755 "$APP/Contents/MacOS/BirdLockInterpolation"
chmod 755 "$APP/Contents/MacOS/BirdLock"
cp VERSION "$APP/Contents/Resources/"
cp -R SharedResources/Audio "$APP/Contents/Resources/Audio"
cp -R SharedResources/Support "$APP/Contents/Resources/Support"
cp -R SharedResources/AircraftModels "$APP/Contents/Resources/AircraftModels"
cp -R Models/*.mlmodelc "$APP/Contents/Resources/Models/"
cp Models/*.json "$APP/Contents/Resources/Models/" 2>/dev/null || true
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Bundled documents: agreement, licenses, manual (HTML + PDF)
DOCS="$APP/Contents/Resources/Docs"
mkdir -p "$DOCS"
cp docs/用户协议.md docs/第三方许可.md docs/使用说明.md LICENSE "$DOCS/"
python3 -I scripts/md2html.py docs/使用说明.md "$DOCS/使用说明.html"
HTML2PDF="$ROOT/.build/html2pdf"
[ "$HTML2PDF" -nt scripts/html2pdf.swift ] || swiftc -O scripts/html2pdf.swift -o "$HTML2PDF"
"$HTML2PDF" "$DOCS/使用说明.html" "$DOCS/使用说明.pdf" >/dev/null

BUILD="$(date +%Y%m%d%H%M)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>BirdLock</string>
  <key>CFBundleIdentifier</key><string>local.birdlock.app</string>
  <key>CFBundleName</key><string>BirdLock</string>
  <key>CFBundleDisplayName</key><string>鸟眼锁定</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>连拍文件夹</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>照片</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.jpeg</string><string>public.heic</string><string>public.heif</string><string>public.png</string><string>public.tiff</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
VERIFY_ARGS=()
[ "${UNIVERSAL:-0}" = "1" ] && VERIFY_ARGS=(--universal)
python3 -I scripts/verify_bundle.py "$APP" --version "$VERSION" "${VERIFY_ARGS[@]}"
echo "✅ 已生成 $APP"
