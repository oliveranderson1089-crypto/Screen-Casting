#!/usr/bin/env bash
# vivo 手机投屏到电脑（scrcpy 封装）
#
# 用法：
#   phone-cast.sh          自动选择：优先 USB，没插线就走无线
#   phone-cast.sh usb      强制走 USB
#   phone-cast.sh wifi     强制走无线（记录的 IP 连不上会自动扫网段找）
#   phone-cast.sh setup    插着 USB 线跑一次，重新打通无线（手机重启后需要）
#   phone-cast.sh find     只搜索手机、更新 IP 记录，不启动投屏
#   phone-cast.sh off      断开无线连接
set -euo pipefail

PORT=5555
STATE_DIR="$HOME/AppStore/data/phone-cast"
IP_FILE="$STATE_DIR/last-ip"
SERIAL_FILE="$STATE_DIR/serial"   # 手机硬件序列号，用来确认扫到的是自己的设备

# 无线带宽有限，码率给低一点；USB 不心疼带宽
BITRATE_WIFI="12M"
BITRATE_USB="24M"

# 系统 /usr/bin/adb 是 34.0.5-debian，SDK 里那份是官方 37.0.0。
# 两个版本会互相 kill 掉对方的 5037 server（投屏和打 APK 撞车），统一用新的那份。
ADB_BIN="$HOME/AppStore/toolchains/android-sdk/platform-tools/adb"
[[ -x "$ADB_BIN" ]] || ADB_BIN="$(command -v adb)"
export ADB="$ADB_BIN"          # scrcpy 认这个环境变量来找 adb
adb() { "$ADB_BIN" "$@"; }     # 脚本内所有 adb 调用统一走它

mkdir -p "$STATE_DIR"

# ---- 从桌面图标启动时没有终端，错误要弹窗，否则用户什么都看不到 ----
die() {
  # 消息里的 \n 要真的换行，终端和 zenity 都得先展开
  local msg
  msg="$(printf '%b' "$*")"
  printf '%s\n' "$msg" >&2
  if [[ ! -t 2 ]] && command -v zenity >/dev/null 2>&1; then
    zenity --error --title="投屏失败" --text="$msg" --width=380 2>/dev/null || true
  fi
  exit 1
}

note() {
  local msg="$*"
  echo "$msg"
  if [[ ! -t 1 ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send -i scrcpy "手机投屏" "$msg" 2>/dev/null || true
  fi
}

# ---- 取当前插着的 USB 设备序列号（无线设备的序列号形如 IP:PORT，排除掉）----
usb_serial() {
  adb devices | awk '/\tdevice$/ {print $1}' | grep -v ':' | head -1
}

# ---- 从手机里读它自己的 WiFi IP ----
phone_ip() {
  local serial="$1"
  adb -s "$serial" shell ip -f inet addr show wlan0 2>/dev/null \
    | awk '/inet /{split($2, a, "/"); print a[1]}' | head -1
}

# ---- 手机的硬件序列号，换网络后靠它认人 ----
hw_serial() {
  adb -s "$1" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n'
}

remember() {
  local ip="$1" serial="$2"
  echo "$ip" > "$IP_FILE"
  [[ -n "$serial" ]] && echo "$serial" > "$SERIAL_FILE"
}

# =============== 无线连接 ===============

# 端口探测比 adb connect 快得多，先探再连，避免对着不可达的 IP 干等
port_open() {
  timeout 1 bash -c "echo > /dev/tcp/$1/$PORT" 2>/dev/null
}

try_connect() {
  local ip="$1"
  adb devices | grep -q "^$ip:$PORT[[:space:]]*device$" && return 0
  port_open "$ip" || return 1
  adb connect "$ip:$PORT" 2>&1 | grep -qE 'connected'
}

# 本机所在的 /24 网段前缀（形如 192.168.3），多网卡同网段时去重
local_prefixes() {
  ip -o -f inet addr show scope global 2>/dev/null \
    | awk '{print $4}' | grep '/24$' \
    | cut -d/ -f1 | cut -d. -f1-3 | sort -u
}

# 扫一个网段里开着 5555 端口的地址（64 路并发，整段约 4 秒）
# 超时给到 1 秒：手机休眠时 WiFi 进省电模式，第一个包要先唤醒无线模块，
# 0.3 秒会漏报。网段里其他开着 5555 的设备由后面的序列号校验排除。
scan_prefix() {
  local prefix="$1"
  seq 1 254 | xargs -P 64 -I{} bash -c \
    "timeout 1 bash -c 'echo > /dev/tcp/$prefix.{}/$PORT' 2>/dev/null && echo $prefix.{}" 2>/dev/null
}

# 换了 WiFi / 开了热点导致 IP 变化时，靠序列号在当前网段里把手机找回来。
# adb tcpip 让 adbd 监听所有网络接口，所以只要手机没重启，新网络下 5555 照样开着。
find_phone() {
  local want ip serial prefix
  want="$(cat "$SERIAL_FILE" 2>/dev/null || true)"
  [[ -n "$want" ]] || return 1

  for prefix in $(local_prefixes); do
    for ip in $(scan_prefix "$prefix"); do
      adb connect "$ip:$PORT" >/dev/null 2>&1 || continue
      # connect 返回成功时设备可能还是 offline，这时读序列号会拿到空值、
      # 把自己的手机误判成别人的设备。等它真正 ready 再问。
      if ! timeout 5 "$ADB_BIN" -s "$ip:$PORT" wait-for-device >/dev/null 2>&1; then
        adb disconnect "$ip:$PORT" >/dev/null 2>&1 || true
        continue
      fi
      serial="$(hw_serial "$ip:$PORT")"
      if [[ "$serial" == "$want" ]]; then
        remember "$ip" "$serial"
        echo "$ip"
        return 0
      fi
      # 不是自己的设备，断开别占着
      adb disconnect "$ip:$PORT" >/dev/null 2>&1 || true
    done
  done
  return 1
}

# =============== 投屏 ===============

# 手机自然息屏时 Android 会停止渲染主显示，电脑这边就跟着黑了。
# -S 断屏幕面板电源，scrcpy 自己建的 Virtual display 仍在收画面，
# 所以手机全黑省电、电脑照常操作（用户实测确认可用，无线不插电也成立）。
# 注意：此时 dumpsys 会显示 mWakefulness=Asleep，那是正常的，不代表画面断了。
#
# --screen-off-timeout 本想顶住系统的 10 分钟自动锁屏，但 vivo OriginOS 拦截了
# adb 写系统设置（settings put 静默失败、不报错也不生效），所以它在这台机器上无效。
# 保留是为了将来万一开了「USB调试(安全设置)」解锁写权限，无需再改脚本。
SCREEN_TIMEOUT=7200

start_scrcpy() {
  local serial="$1" bitrate="$2" title="$3"
  echo "==> 投屏中：$serial（$title）"
  echo "    手机屏幕已关闭以省电；按 Alt+Shift+O 可点亮手机屏幕"
  exec scrcpy -s "$serial" \
    --window-title="$title" \
    --video-bit-rate="$bitrate" \
    --max-fps=60 \
    --turn-screen-off \
    --stay-awake \
    --screen-off-timeout="$SCREEN_TIMEOUT" \
    --power-off-on-close
}

# ---- 打通无线：需要 USB 线在位 ----
setup_wifi() {
  local serial ip hw
  serial="$(usb_serial)"
  [[ -n "$serial" ]] || die "没检测到 USB 设备。\n请插上数据线，确认手机已开「USB 调试」后重试。"

  ip="$(phone_ip "$serial")"
  [[ -n "$ip" ]] || die "读不到手机的 WiFi IP。\n确认手机已连上 WiFi。"

  hw="$(hw_serial "$serial")"

  echo "==> 手机 IP：$ip，切换 adb 到 TCP 模式（会短暂断开）"
  adb -s "$serial" tcpip "$PORT" >/dev/null
  sleep 3
  adb connect "$ip:$PORT"
  remember "$ip" "$hw"
  note "无线已打通（$ip），之后拔线也能直接投屏。"
}

connect_wifi() {
  local ip=""
  [[ -f "$IP_FILE" ]] && ip="$(cat "$IP_FILE")"

  # 1) 记录的 IP 还通就直接用
  if [[ -n "$ip" ]] && try_connect "$ip"; then
    start_scrcpy "$ip:$PORT" "$BITRATE_WIFI" "vivo 投屏（无线）"
  fi

  # 2) 不通就在当前网段里找（换了 WiFi、开了热点都属于这种）
  [[ -f "$SERIAL_FILE" ]] || die "还没打通过无线。\n请插上 USB 线，再从右键菜单选「重新打通无线」。"

  note "记录的地址连不上，正在当前网段搜索手机…"
  local found
  if found="$(find_phone)"; then
    note "找到了：$found"
    start_scrcpy "$found:$PORT" "$BITRATE_WIFI" "vivo 投屏（无线）"
  fi

  die "在当前网段没找到手机。请依次排查：\n\n1) 先点亮手机屏幕——手机深度休眠时 WiFi 会断，端口扫不到（最常见）\n2) 手机和电脑连的是同一个 WiFi（或电脑连了手机热点）\n3) 手机没有重启过——重启会关掉无线调试，需插 USB 线选「重新打通无线」\n4) 路由器没开「AP 隔离 / 客户端隔离」"
}

connect_usb() {
  local serial
  serial="$(usb_serial)"
  [[ -n "$serial" ]] || die "没检测到 USB 设备。\n请插上数据线，并把 USB 用途设为「管理文件」。"
  start_scrcpy "$serial" "$BITRATE_USB" "vivo 投屏（USB）"
}

case "${1:-auto}" in
  usb)   connect_usb ;;
  wifi)  connect_wifi ;;
  setup) setup_wifi ;;
  find)
    if found="$(find_phone)"; then
      note "找到手机：$found（已更新记录）"
    else
      die "没找到手机。\n确认手机与电脑在同一局域网、且手机没重启过。"
    fi
    ;;
  off)
    adb disconnect >/dev/null 2>&1 || true
    note "已断开所有无线 adb 连接。"
    ;;
  auto)
    if [[ -n "$(usb_serial)" ]]; then
      connect_usb
    else
      connect_wifi
    fi
    ;;
  *)
    echo "未知参数：$1" >&2
    sed -n '2,12p' "$0" >&2
    exit 1
    ;;
esac
