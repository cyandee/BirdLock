#!/bin/zsh
# 生成发布压缩包：dist/BirdLock鸟眼锁定-<版本>.zip
#   BirdLock.app（Apple 芯片 + Intel 通用版，内置使用说明、用户协议、许可）
#   使用说明.pdf、用户协议.pdf、安装步骤.txt、LICENSE.txt（AGPL-3.0）
#   源代码/BirdLock-<版本>-source.zip（AGPL-3.0 要求随软件提供完整源代码）
# 用法：VERSION=1.0 LABEL=测试版 zsh scripts/make_release.sh
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="${VERSION:-1.0}"
LABEL="${LABEL:-测试版}"
NAME="BirdLock鸟眼锁定-${VERSION}${LABEL}"

UNIVERSAL=1 VERSION="$VERSION" zsh scripts/build_app.sh

STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE/源代码"
ditto dist/BirdLock.app "$STAGE/BirdLock.app"
DOCS=dist/BirdLock.app/Contents/Resources/Docs
cp "$DOCS/使用说明.pdf" "$STAGE/"
python3 -I scripts/md2html.py docs/用户协议.md "$STAGE/.agreement.html"
"$ROOT/.build/html2pdf" "$STAGE/.agreement.html" "$STAGE/用户协议.pdf" >/dev/null
rm -f "$STAGE/.agreement.html"
cp LICENSE "$STAGE/LICENSE.txt"
cat > "$STAGE/安装步骤.txt" <<TXT
BirdLock 鸟眼锁定 ${VERSION} ${LABEL}

1. 把「BirdLock.app」拖到「应用程序」文件夹。
2. 双击打开。如果提示“无法验证开发者”：先点「完成」，再打开「系统设置 → 隐私与安全性」，
   在下方找到 BirdLock，点「仍要打开」。（本软件暂未做 Apple 公证）
   如果提示“已损坏，无法打开”：打开「终端」，运行
   xattr -dr com.apple.quarantine /Applications/BirdLock.app
   然后再打开。
3. 第一次打开会显示用户协议，阅读后点「同意并继续」。
4. 详细用法见「使用说明.pdf」，或软件菜单「帮助 → BirdLock 使用说明」。

系统要求：macOS 14 或更高版本（Apple 芯片或 Intel）。
本软件依据 GNU AGPL-3.0 开源，完整源代码见「源代码」文件夹。
意见反馈：cyanodee@foxmail.com
TXT

# Corresponding source: every tracked + new (not ignored) file of the repo
SRC="$(mktemp -d)/BirdLock-$VERSION-source"
mkdir -p "$SRC"
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
  [ -f "$f" ] && ditto "$f" "$SRC/$f"
done
(cd "${SRC:h}" && ditto -c -k --keepParent "BirdLock-$VERSION-source" "$STAGE/源代码/BirdLock-$VERSION-source.zip")
rm -rf "${SRC:h}"

OUT="$ROOT/dist/$NAME.zip"
rm -f "$OUT"
(cd "${STAGE:h}" && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$OUT")
rm -rf "${STAGE:h}"
echo "✅ 已生成 $OUT（$(du -h "$OUT" | cut -f1)）"
