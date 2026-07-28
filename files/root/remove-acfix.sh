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
