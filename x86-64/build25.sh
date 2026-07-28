#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p /home/build/immortalwrt/files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > /home/build/immortalwrt/files/etc/openclash/core/clash_meta
    chmod +x /home/build/immortalwrt/files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O /home/build/immortalwrt/files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O /home/build/immortalwrt/files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    if [ -z "$URL" ]; then
        echo "❌ 获取 OpenClash 下载地址失败（可能是 GitHub API 限流）"
        exit 1
    fi
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p /home/build/immortalwrt/files/usr/bin
    # Download mihomo
   MIHOMO_URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*"' \
      | cut -d'"' -f4 \
      | grep 'linux-amd64-.*\.gz$' \
      | grep -v 'compatible' \
      | head -n1)
    if [ -z "$MIHOMO_URL" ]; then
        echo "❌ 获取 mihomo 下载地址失败（可能是 GitHub API 限流）"
        exit 1
    fi
    echo "mihomo latest: $MIHOMO_URL"
    wget -qO- "$MIHOMO_URL" | gzip -dc > /home/build/immortalwrt/files/usr/bin/mihomo
    chmod +x /home/build/immortalwrt/files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah /home/build/immortalwrt/files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

PKGDIR=/home/build/immortalwrt/packages
mkdir -p "$PKGDIR"

# 通用函数：从 GitHub 最新 Release 下载匹配资产并解出 apk
fetch_apk() {
  local repo="$1" pattern="$2"
  local workdir
  workdir=$(mktemp -d)
  local url
  url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | cut -d'"' -f4 | grep -E "$pattern" | head -n1)
  if [ -z "$url" ]; then
    echo "!! 未找到资产: ${repo} ${pattern}"; rm -rf "$workdir"; return 1
  fi
  echo "下载: $url"
  curl -sL -o "$workdir/pkg.bin" "$url"
  case "$url" in
    *.zip) (cd "$workdir" && unzip -oq pkg.bin) ;;
    *)     tar -xzf "$workdir/pkg.bin" -C "$workdir" ;;
  esac
  find "$workdir" -name '*.apk' -exec cp {} "$PKGDIR/" \;
  rm -rf "$workdir"
}
FAILED=0
fetch_apk "sirpdboy/netspeedtest"      'SNAPSHOT-x86_64\.tar\.gz$' || FAILED=1
fetch_apk "sbwml/luci-app-mosdns"      'x86_64.*(openwrt-25\.12|SNAPSHOT)\.tar\.gz$' || FAILED=1
fetch_apk "nikkinikki-org/OpenWrt-momo" 'momo_x86_64-openwrt-25\.12\.tar\.gz$' || FAILED=1
fetch_apk "sirpdboy/luci-app-advancedplus" '\.apk' || FAILED=1

if [ "$FAILED" = "1" ]; then
  echo "❌ 有第三方 apk 下载失败，请检查上方日志中的资产名是否匹配"
  exit 1
fi
(
  cd "$PKGDIR" || exit 1
  for f in *.apk; do
    [ -e "$f" ] || continue
    newname=$(echo "$f" | sed -E 's/-[0-9][^-]*\.apk$/.apk/')
    if [ "$f" != "$newname" ]; then
      echo "重命名: $f -> $newname"
      mv -f "$f" "$newname"
    fi
  done
)
echo "=== packages 目录最终内容 ==="
ls -lah "$PKGDIR"

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

cd /home/build/immortalwrt
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
