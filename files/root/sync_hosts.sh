#!/bin/sh

HOSTS_FILE="/etc/hosts"
MARKER_START="# === NEXTDNS STATIC HOSTS BEGIN ==="
MARKER_END="# === NEXTDNS STATIC HOSTS END ==="

# 1. 移除旧的动态区块（包括标记行本身）
sed -i "/^$MARKER_START$/,/^$MARKER_END$/d" "$HOSTS_FILE"

# 2. 写入区块开始标记
echo "$MARKER_START" >> "$HOSTS_FILE"

# 3. 处理 DHCP 静态租约
echo "# --- DHCP Static Leases ---" >> "$HOSTS_FILE"
uci show dhcp | grep "=host" | cut -d'[' -f2 | cut -d']' -f1 | sort -un | while read idx; do
    ip=$(uci -q get dhcp.@host[$idx].ip)
    name=$(uci -q get dhcp.@host[$idx].name)
    if [ -n "$ip" ] && [ -n "$name" ]; then
        echo "$ip $name" >> "$HOSTS_FILE"
    fi
done

# 4. 处理 WireGuard 设备
echo "# --- WireGuard Peers ---" >> "$HOSTS_FILE"
uci show network | grep "=wireguard_wg" | cut -d'[' -f2 | cut -d']' -f1 | sort -un | while read idx; do
    # 提取 IP（自动去掉 /32 等掩码）
    ip=$(uci -q get network.@wireguard_wg[$idx].allowed_ips | cut -d'/' -f1)
    # 提取描述作为设备名
    name=$(uci -q get network.@wireguard_wg[$idx].description)
    
    if [ -n "$ip" ] && [ -n "$name" ]; then
        echo "$ip $name" >> "$HOSTS_FILE"        
    fi
done

# 5. 写入区块结束标记
echo "$MARKER_END" >> "$HOSTS_FILE"

# 6. 重启服务
/etc/init.d/dnsmasq restart
/etc/init.d/nextdns restart

echo "Hosts 同步完成！WireGuard 和 DHCP 设备已写入 /etc/hosts"
