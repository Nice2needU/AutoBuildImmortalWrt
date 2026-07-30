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
  # 稍后会在所有自定义 APK 下载完成后统一处理并建立索引
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
# PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ======== 本脚本下载到 packages/ 的第三方 APK ========

# 高级设置
PACKAGES="$PACKAGES luci-app-advancedplus"
PACKAGES="$PACKAGES luci-i18n-advancedplus-zh-cn"

# 网络测速
PACKAGES="$PACKAGES luci-app-netspeedtest"
PACKAGES="$PACKAGES luci-i18n-netspeedtest-zh-cn"

# MosDNS
PACKAGES="$PACKAGES luci-app-mosdns"
PACKAGES="$PACKAGES luci-i18n-mosdns-zh-cn"

# momo
PACKAGES="$PACKAGES momo"
PACKAGES="$PACKAGES luci-app-momo"
PACKAGES="$PACKAGES luci-i18n-momo-zh-cn"

# AdGuardHome 核心使用 ImmortalWrt 官方包
PACKAGES="$PACKAGES adguardhome"

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
    *.apk) cp "$workdir/pkg.bin" "$PKGDIR/$(basename "$url")"; rm -rf "$workdir"; return 0 ;;
    *)     tar -xzf "$workdir/pkg.bin" -C "$workdir" ;;
  esac
  local count
  count=$(find "$workdir" -name '*.apk' | wc -l)
  if [ "$count" -eq 0 ]; then
    echo "!! ${repo} 解压后未找到任何 apk 文件"; rm -rf "$workdir"; return 1
  fi
  echo "✅ ${repo}: 找到 ${count} 个 apk"
  find "$workdir" -name '*.apk' -exec cp {} "$PKGDIR/" \;
  rm -rf "$workdir"
}
FAILED=0
fetch_apk "sirpdboy/netspeedtest"      'SNAPSHOT-x86_64\.tar\.gz$' || FAILED=1
fetch_apk "sbwml/luci-app-mosdns"      'x86_64.*(openwrt-25\.12|SNAPSHOT)\.tar\.gz$' || FAILED=1
fetch_apk "nikkinikki-org/OpenWrt-momo" 'momo_x86_64-openwrt-25\.12\.tar\.gz$' || FAILED=1
# advancedplus 直接下载 apk 文件（非压缩包）
ADV_URLS=$(curl -s https://api.github.com/repos/sirpdboy/luci-app-advancedplus/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*\.apk"' \
  | cut -d'"' -f4)
if [ -z "$ADV_URLS" ]; then
  echo "❌ 未找到 advancedplus 的 apk 资产"
  exit 1
fi
for u in $ADV_URLS; do
  echo "下载: $u"
  curl -sL -o "$PKGDIR/$(basename "$u")" "$u"
done

# Steven 的 AdGuardHome LuCI 插件：下载最新 Release 的主插件及中文包
ADG_URLS=$(
  curl -fsSL \
    https://api.github.com/repos/stevenjoezhang/luci-app-adguardhome/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*\.apk"' \
    | cut -d'"' -f4 \
    | grep -E \
      '/(luci-app-adguardhome-[^/]+|luci-i18n-adguardhome-zh-cn-[^/]+)\.apk$' \
    || true
)

ADG_APP_FOUND=0
ADG_I18N_FOUND=0
ADG_APP_VERSION=""
ADG_I18N_VERSION=""

if [ -z "$ADG_URLS" ]; then
  echo "❌ 未找到 Steven AdGuardHome 的 APK 资产"
  FAILED=1
else
  for u in $ADG_URLS; do
    pkg_name=$(basename "$u")
    echo "下载 AdGuardHome APK: $pkg_name"

    if ! curl -fsSL -o "$PKGDIR/$pkg_name" "$u"; then
      echo "❌ 下载失败: $pkg_name"
      FAILED=1
      continue
    fi

    case "$pkg_name" in
      luci-app-adguardhome-*.apk)
        ADG_APP_FOUND=1
        ADG_APP_VERSION=$(
          echo "$pkg_name" \
            | sed -E 's/^luci-app-adguardhome-(.+)\.apk$/\1/'
        )
        ;;
      luci-i18n-adguardhome-zh-cn-*.apk)
        ADG_I18N_FOUND=1
        ADG_I18N_VERSION=$(
          echo "$pkg_name" \
            | sed -E \
              's/^luci-i18n-adguardhome-zh-cn-(.+)\.apk$/\1/'
        )
        ;;
    esac
  done
fi

if [ "$ADG_APP_FOUND" != "1" ] || [ "$ADG_I18N_FOUND" != "1" ]; then
  echo "❌ AdGuardHome 主插件或中文包未完整下载"
  FAILED=1
else
  echo "✅ Steven AdGuardHome 主插件版本: $ADG_APP_VERSION"
  echo "✅ Steven AdGuardHome 中文包版本: $ADG_I18N_VERSION"

  PACKAGES="$PACKAGES luci-app-adguardhome=$ADG_APP_VERSION"
  PACKAGES="$PACKAGES luci-i18n-adguardhome-zh-cn=$ADG_I18N_VERSION"
fi

if [ "$FAILED" = "1" ]; then
  echo "❌ 有第三方 apk 下载失败，请检查上方日志中的资产名是否匹配"
  exit 1
fi

echo "=== 处理 extra-packages 并准备本地第三方 APK ==="
sh shell/apk-prepare-packages.sh

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
