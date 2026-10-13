#!/bin/zsh
# 构建 BirdLock.app（Release），输出到 dist/BirdLock.app
# 用法：zsh scripts/build_app.sh
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product BirdLock
BIN="$(swift build -c release --show-bin-path)/BirdLock"

APP="$ROOT/dist/BirdLock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Models"
cp "$BIN" "$APP/Contents/MacOS/BirdLock"
cp -R Models/*.mlmodelc "$APP/Contents/Resources/Models/"
cp Models/*.json "$APP/Contents/Resources/Models/" 2>/dev/null || true
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

VERSION="${VERSION:-1.0}"
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
echo "✅ 已生成 $APP"
