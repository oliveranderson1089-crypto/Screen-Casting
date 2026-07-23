#!/usr/bin/env bash
# 安装 phone-cast：生成桌面图标、注册到应用列表。
# 幂等，可重复运行。卸载见文末提示。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO_DIR/phone-cast.sh"
APPS_DIR="$HOME/.local/share/applications"
DESKTOP="$APPS_DIR/phone-cast.desktop"

command -v scrcpy >/dev/null 2>&1 || echo "⚠ 未检测到 scrcpy，投屏前请先安装：sudo apt install scrcpy"
command -v adb    >/dev/null 2>&1 || echo "⚠ 未检测到 adb，请先安装：sudo apt install adb"

chmod +x "$SCRIPT"
mkdir -p "$APPS_DIR"

# ---- 生成桌面图标（Exec 指向本仓库里的脚本）----
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=手机投屏
GenericName=Phone Screen Mirror
Comment=把安卓手机投屏到电脑（scrcpy）
Exec=$SCRIPT
Icon=scrcpy
Terminal=false
Categories=Utility;Network;RemoteAccess;
Keywords=scrcpy;phone;mirror;android;投屏;手机;touping;
StartupNotify=true
Actions=usb;wifi;desktop;setup;off;

[Desktop Action usb]
Name=USB 投屏（画质最好）
Exec=$SCRIPT usb

[Desktop Action wifi]
Name=无线投屏
Exec=$SCRIPT wifi

[Desktop Action desktop]
Name=独立桌面（手机主屏可休眠）
Exec=$SCRIPT desktop

[Desktop Action setup]
Name=重新打通无线（需插线）
Exec=$SCRIPT setup

[Desktop Action off]
Name=断开无线连接
Exec=$SCRIPT off
EOF

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
echo "✓ 已安装桌面图标：$DESKTOP"

# ---- GNOME：把图标追加到应用网格末尾（漏加是 GNOME 的老毛病，主动补上）----
if command -v gsettings >/dev/null 2>&1 && python3 -c 'import gi' 2>/dev/null; then
  python3 - <<'PY' || true
from gi.repository import Gio, GLib
APP_ID = "phone-cast.desktop"
s = Gio.Settings.new("org.gnome.shell")
pages = s.get_value("app-picker-layout").unpack()
if pages and not any(APP_ID in p for p in pages):
    last = pages[-1]
    pos = max((v.get("position", 0) for v in last.values()), default=-1) + 1
    last[APP_ID] = {"position": pos}
    s.set_value("app-picker-layout", GLib.Variant("aa{sv}", [
        {k: GLib.Variant("a{sv}", {"position": GLib.Variant("i", v["position"])})
         for k, v in page.items()} for page in pages]))
    Gio.Settings.sync()
    print("✓ 已加入 GNOME 应用网格")
PY
fi

echo
echo "完成。按 Super 键搜「投屏」即可找到，或直接运行：$SCRIPT"
echo "卸载：rm \"$DESKTOP\" && update-desktop-database \"$APPS_DIR\""
