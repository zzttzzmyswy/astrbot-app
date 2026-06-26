#!/usr/bin/env bash
# 将 Flutter linux release bundle 打包成单文件 AppImage(免安装、下载即运行)。
# 产物:build/astrbot_app-x86_64.AppImage
# 依赖:flutter(本机)、curl、python3+PIL(图标放大)、appimagetool(自动下载)。
set -euo pipefail
cd "$(dirname "$0")/.."

flutter build linux --release

BUNDLE=build/linux/x64/release/bundle
APPDIR=build/AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"

# AppRun:AppImage 入口。设 LD_LIBRARY_PATH 双保险(RUNPATH 已是 $ORIGIN/lib,布局保住即可)。
cat > "$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
cd "${HERE}/usr/bin"
exec "${HERE}/usr/bin/astrbot_app" "$@"
RUN
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/astrbot_app.desktop" <<'DESK'
[Desktop Entry]
Name=AstrBot
Comment=AstrBot BotAPI 桌面客户端
Exec=astrbot_app
Icon=astrbot_app
Type=Application
Categories=Network;Utility;
Terminal=false
DESK

# 图标:取 Android launcher 最高清(192),放大到 512(AppImage 推荐 ≥256)。
python3 - <<'PY'
from PIL import Image
im = Image.open('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png').convert('RGBA')
im = im.resize((512, 512), Image.LANCZOS)
im.save('build/AppDir/astrbot_app.png')
PY
ln -sf astrbot_app.png "$APPDIR/.DirIcon"

# appimagetool(单文件,自动下载)。FUSE 不可用时用 --appimage-extract-and-run。
mkdir -p build/tools
T=build/tools/appimagetool
if [ ! -x "$T" ]; then
  curl -fsSL -o "$T" https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$T"
fi
"$T" --appimage-extract-and-run "$APPDIR" build/astrbot_app-x86_64.AppImage

echo "✓ $(ls -lh build/astrbot_app-x86_64.AppImage | awk '{print $5, $9}')"
