#!/bin/zsh
# 打包可分发的安装镜像：dist/BirdLock-<版本>.dmg（Apple 芯片 + Intel 通用版，拖到「应用程序」即可安装）
# 用法：VERSION=1.1 zsh scripts/make_dmg.sh
# 注意：没有 Apple 开发者证书时只能做临时签名（ad-hoc），别人第一次打开需要在
#      「系统设置 → 隐私与安全性」里点「仍要打开」。有 Developer ID 时设置 SIGN_ID 并公证即可免去这一步。
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="${VERSION:-1.0}"
UNIVERSAL=1 VERSION="$VERSION" zsh scripts/build_app.sh

APP="$ROOT/dist/BirdLock.app"
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
cp "$APP/Contents/Resources/Docs/使用说明.pdf" "$STAGE/"
cp "$APP/Contents/Resources/Docs/LICENSE" "$STAGE/LICENSE.txt"

DMG="$ROOT/dist/BirdLock-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "BirdLock 鸟眼锁定 $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
[ -n "$SIGN_ID" ] && codesign --sign "$SIGN_ID" --timestamp "$DMG"
echo "✅ 已生成 $DMG（$(du -h "$DMG" | cut -f1)）"
