#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN="iphone.frankj.top"
DNS_SERVER="piper.ns.cloudflare.com"
SECTION="iphone_ddns64"
LOG="/tmp/iphone-ddns64.log"

log()
{
echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
logger -t iphone-ddns64 "$*"
}

log "脚本开始运行"

# 只提取域名答案部分中的最后一个 IPv6 地址，
# 避免把 DNS 服务器地址本身当成查询结果。
IP=$(
nslookup "$DOMAIN" "$DNS_SERVER" 2>/dev/null |
awk '
/^Name:/ {
answer = 1
next
}
answer && /^Address( [0-9]+)?:/ {
print $NF
}
' |
grep -E '^[0-9A-Fa-f:]+$' |
grep ':' |
tail -n 1
)

if [ -z "$IP" ]; then
log "错误：未从 $DOMAIN 解析到 IPv6 地址"
exit 1
fi

log "DNS 解析结果：$IP"

# 确认防火墙规则配置段存在
if ! uci -q get "firewall.$SECTION" >/dev/null 2>&1; then
log "错误：找不到 firewall.$SECTION 配置段"
exit 1
fi

NEW="${IP}/64"
OLD=$(uci -q get "firewall.$SECTION.src_ip")

log "当前规则：${OLD:-未设置}"
log "准备更新：$NEW"

# 使用 /tmp 中的完整 IP 记录，避免每分钟重复写入 flash
LAST_IP=$(cat /tmp/iphone-ddns64.last 2>/dev/null)

if [ "$IP" = "$LAST_IP" ] && [ -n "$OLD" ]; then
log "IPv6 未变化，无需更新"
exit 0
fi

# 暂时设置新值，先执行 fw4 校验
uci set "firewall.$SECTION.src_ip=$NEW"

if ! fw4 check >> "$LOG" 2>&1; then
log "错误：新防火墙配置未通过 fw4 check，正在恢复"

if [ -n "$OLD" ]; then
uci set "firewall.$SECTION.src_ip=$OLD"
else
uci revert firewall
fi

exit 1
fi

# 校验通过后再写入配置
uci commit firewall

if /etc/init.d/firewall reload >> "$LOG" 2>&1; then
echo "$IP" > /tmp/iphone-ddns64.last
log "更新成功：$NEW"
exit 0
fi

log "错误：firewall reload 失败，恢复旧规则"

if [ -n "$OLD" ]; then
uci set "firewall.$SECTION.src_ip=$OLD"
uci commit firewall
/etc/init.d/firewall reload >> "$LOG" 2>&1
fi

exit 1
