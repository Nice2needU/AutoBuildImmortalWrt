#!/bin/sh
# 一键部署 / 升级：
#  - /usr/bin/acfix-fix              ：AC 修复逻辑（静态 ARP + GARP）
#  - /usr/bin/acfix-watch v2         ：智能 AC 监控（单实例 + 冷却时间）
#  - /etc/init.d/acfix-watch         ：procd 服务
#  - /etc/hotplug.d/net/99-ac-fix    ：eth1.20 热插拔时自动修 AC
#  - /etc/hotplug.d/net/99-delay-wan ：利用 net 热插拔延迟 PPPoE 拨号 + debug 日志

set -e

echo "[acfix] 写入 /usr/bin/acfix-fix ..."
cat << 'EOF_FIX' > /usr/bin/acfix-fix
#!/bin/sh
# 统一 AC 修复逻辑：静态 ARP + GARP

LOGTAG="acfix-fix"
AC_IP="192.168.20.2"
AC_GW="192.168.20.1"
AC_MAC="9C:47:82:43:04:AC"
DEV="eth1.20"

# 写静态 ARP（上游看到 AC）
ip neigh replace "$AC_IP" dev "$DEV" lladdr "$AC_MAC" nud permanent 2>/dev/null

# 刷新 ImmortalWrt -> AC 的 ARP
arping -U -c 2 -I "$DEV" "$AC_IP" >/dev/null 2>&1

# 刷新 AC -> 192.168.20.1 的 ARP
arping -A -c 1 -I "$DEV" "$AC_GW" >/dev/null 2>&1

# 简单联通性测试（给 logread 看）
if ping -c 1 -W 1 "$AC_IP" >/dev/null 2>&1; then
    logger -t "$LOGTAG" "AC $AC_IP reachable after fix"
else
    logger -t "$LOGTAG" "WARNING: AC $AC_IP still unreachable after fix"
fi
EOF_FIX
chmod +x /usr/bin/acfix-fix

echo "[acfix] 写入智能版 /usr/bin/acfix-watch v2 ..."
cat << 'EOF_WATCH' > /usr/bin/acfix-watch
#!/bin/sh
# 智能版 AC 监控：考虑链路状态 + 连续失败 + 冷却时间 + 单实例锁
LOGTAG="acfix-watch"
AC_IP="192.168.20.2"
DEV="eth1.20"

SLEEP_SEC=10         # 检测间隔（秒）
FAIL_THRESHOLD=3     # 连续多少次 ping 失败才认定为 unreachable
COOLDOWN_SEC=60      # 两次修复之间的最小间隔（秒）

# 简单单实例锁，防止误多开
LOCK_DIR="/var/run/acfix-watch.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    logger -t "$LOGTAG" "another instance already running, exiting."
    exit 0
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

logger -t "$LOGTAG" "started (interval=${SLEEP_SEC}s, target=$AC_IP, dev=$DEV)"

fail_count=0
last_fix_ts=0
last_state="unknown"    # ok / bad / link-down / unknown

while true; do
    # 1. 先看接口状态，如果 eth1.20 本身就没 up，说明 AC 在重启或没插好线
    if [ -d "/sys/class/net/$DEV" ]; then
        operstate="$(cat /sys/class/net/$DEV/operstate 2>/dev/null)"
    else
        operstate="unknown"
    fi

    if [ "$operstate" != "up" ]; then
        # 接口没起来，没必要刷 acfix-fix，等下一轮
        if [ "$last_state" != "link-down" ]; then
            logger -t "$LOGTAG" "dev $DEV operstate=$operstate, link not up — skip check."
            last_state="link-down"
        fi
        fail_count=0
        sleep "$SLEEP_SEC"
        continue
    fi

    # 2. 接口是 up，再尝试 ping AC
    if ping -c 1 -W 1 "$AC_IP" >/dev/null 2>&1; then
        # 如果之前是 bad，现在恢复了，打一条恢复日志
        if [ "$last_state" = "bad" ]; then
            logger -t "$LOGTAG" "AC $AC_IP reachable again, fail_count reset."
        fi
        last_state="ok"
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
            now_ts="$(date +%s 2>/dev/null)"
            can_fix=1

            if [ -n "$now_ts" ] && [ "$last_fix_ts" -gt 0 ]; then
                diff=$((now_ts - last_fix_ts))
                if [ "$diff" -lt "$COOLDOWN_SEC" ]; then
                    can_fix=0
                fi
            fi

            if [ "$can_fix" -eq 1 ]; then
                logger -t "$LOGTAG" "AC $AC_IP unreachable (fail_count=$fail_count, dev=$DEV) — running acfix-fix"
                /usr/bin/acfix-fix
                last_fix_ts="$now_ts"
                last_state="bad"
            fi
        fi
    fi

    sleep "$SLEEP_SEC"
done
EOF_WATCH
chmod +x /usr/bin/acfix-watch

echo "[acfix] 写入 /etc/init.d/acfix-watch (procd 服务) ..."
cat << 'EOF_INIT' > /etc/init.d/acfix-watch
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1
PROG="/usr/bin/acfix-watch"

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    # respawn: 最小间隔 最大间隔 最大重启次数(0=不限)
    procd_set_param respawn 5 60 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF_INIT
chmod +x /etc/init.d/acfix-watch

echo "[acfix] 写入 /etc/hotplug.d/net/99-ac-fix ..."
mkdir -p /etc/hotplug.d/net
cat << 'EOF_HOTPLUG_NET' > /etc/hotplug.d/net/99-ac-fix
#!/bin/sh
LOGTAG="acfix-pro"
AC_IP="192.168.20.2"

# DEVICE / DEVICENAME 有一个等于 eth1.20 即可
if [ "$DEVICE" != "eth1.20" ] && [ "$DEVICENAME" != "eth1.20" ]; then
    exit 0
fi

STATE_FILE="/tmp/acfix.last_run"
now_ts="$(date +%s 2>/dev/null)"

# 防抖：10 秒内只跑一次
if [ -n "$now_ts" ]; then
    if [ -f "$STATE_FILE" ]; then
        last_ts="$(cat "$STATE_FILE" 2>/dev/null)"
        if [ -n "$last_ts" ]; then
            diff=$((now_ts - last_ts))
            if [ "$diff" -lt 10 ]; then
                logger -t "$LOGTAG" "skip: too frequent (ACTION=$ACTION DEVICE=$DEVICE DEVICENAME=$DEVICENAME)"
                exit 0
            fi
        fi
    fi
    echo "$now_ts" > "$STATE_FILE"
fi

NAME="${DEVICE:-$DEVICENAME}"
logger -t "$LOGTAG" "hotplug on $NAME (ACTION=$ACTION) — calling acfix-fix"
/usr/bin/acfix-fix
EOF_HOTPLUG_NET
chmod +x /etc/hotplug.d/net/99-ac-fix

echo "[acfix] 写入 /etc/hotplug.d/net/99-delay-wan （延迟 PPPoE 拨号 + debug）..."
# 这里使用你提供的 net 版 delay-pppoe 脚本，触发点是 br-lan 的 add 事件
mkdir -p /etc/hotplug.d/net
cat << 'EOF_HOTPLUG_DELAY' > /etc/hotplug.d/net/99-delay-wan
#!/bin/sh
LOGTAG="delay-pppoe"
DELAY_SEC=12
STATE_FILE="/tmp/delay-pppoe.once"

# 记录所有 net hotplug 事件方便调试
echo "$(date) delay-pppoe net hotplug: ACTION=${ACTION} DEVICE=${DEVICE} DEVICENAME=${DEVICENAME}" >> /tmp/delay-pppoe.log

# net 事件里，有的是 DEVICE，有的是 DEVICENAME，这里统一成 NAME
NAME="${DEVICE:-$DEVICENAME}"

# 只在 br-lan add 事件时动作
[ "$NAME" = "br-lan" ] || exit 0

# /etc/hotplug.d/net 这里常见的是 add/remove/link-up/link-down
# 我们只在 add 时动作
[ "$ACTION" = "add" ] || exit 0

# 只处理本次开机的第一次 br-lan 的 add
if [ -f "$STATE_FILE" ]; then
    logger -t "$LOGTAG" "br-lan add (second or later), skip."
    exit 0
fi

date +%s > "$STATE_FILE"

logger -t "$LOGTAG" "eth0 link up detected — delaying PPPoE by ${DELAY_SEC}s, then ifup wan/wan6..."
(
    sleep "$DELAY_SEC"
    /sbin/ifup wan 2>/dev/null
    sleep 1
    /sbin/ifup wan6 2>/dev/null
) &
EOF_HOTPLUG_DELAY
chmod +x /etc/hotplug.d/net/99-delay-wan

echo "[acfix] 启用并重启 acfix-watch 服务 ..."
/etc/init.d/acfix-watch enable >/dev/null 2>&1 || true
/etc/init.d/acfix-watch restart >/dev/null 2>&1 || /etc/init.d/acfix-watch start >/dev/null 2>&1 || true

echo "[acfix] 生成卸载脚本 /root/remove-acfix.sh ..."
cat << 'EOF_UNINSTALL' > /root/remove-acfix.sh
#!/bin/sh
echo "[acfix] 停止 acfix-watch 服务 ..."
/etc/init.d/acfix-watch stop >/dev/null 2>&1 || true
/etc/init.d/acfix-watch disable >/dev/null 2>&1 || true

echo "[acfix] 删除二进制与 init.d ..."
rm -f /usr/bin/acfix-fix
rm -f /usr/bin/acfix-watch
rm -f /etc/init.d/acfix-watch

echo "[acfix] 删除 hotplug 脚本 ..."
rm -f /etc/hotplug.d/net/99-ac-fix
rm -f /etc/hotplug.d/net/99-delay-wan

echo "[acfix] 清理临时状态文件 ..."
rm -rf /var/run/acfix-watch.lock
rm -f /tmp/acfix.last_run
rm -f /tmp/delay-pppoe.once
rm -f /tmp/delay-pppoe.log

echo "[acfix] 完成卸载。如你之前改过 /etc/rc.local，请手动检查是否还残留 acfix-watch 或 ifup wan/wan6 相关行。"
EOF_UNINSTALL
chmod +x /root/remove-acfix.sh

echo
echo "[acfix] 已写入所有组件。"
echo "  日志调试可用：logread -e acfix-watch -e acfix-fix -e acfix-pro -e delay-pppoe"
echo "  net hotplug 调试日志：cat /tmp/delay-pppoe.log"
echo "如果以后想卸载，运行："
echo "  sh /root/remove-acfix.sh"
