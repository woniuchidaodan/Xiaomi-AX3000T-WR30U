#!/bin/bash
# ============================================================
# ImmortalWrt 构建定制脚本
# 用法: bash scripts/customize.sh
# 建议在源码根目录执行，且 defconfig 之后、make download 之前运行
# ============================================================
set -euo pipefail

# ============================================================
# 0. 参数准备
# ============================================================
# DEVICE 通过环境变量传入，例如:
#   DEVICE=AX3000T bash scripts/customize.sh
case "${DEVICE:-}" in
    AX3000T) HOSTNAME="AX3000T" ;;
    WR30U)   HOSTNAME="WR30U"   ;;
    *)       HOSTNAME="ImmortalWrt" ;;
esac
echo "📦 当前设备: ${DEVICE:-未指定}，主机名: $HOSTNAME"

# 基础路径（构建目录下 base-files 的位置）
BASE_FILES="package/base-files/files"

# ============================================================
# 1. 修改默认 IP
# ============================================================
if [ -f "$BASE_FILES/bin/config_generate" ]; then
    sed -i 's/192\.168\.1\.1/192.168.1.2/g' "$BASE_FILES/bin/config_generate"
    echo "✅ 默认 IP 已改为 192.168.1.2"
else
    echo "⚠️ 未找到 $BASE_FILES/bin/config_generate，跳过改 IP"
fi

# ============================================================
# 2. 修改默认主机名
# ============================================================
if [ "$HOSTNAME" != "ImmortalWrt" ] && [ -f "$BASE_FILES/bin/config_generate" ]; then
    sed -i "s/ImmortalWrt/$HOSTNAME/g" "$BASE_FILES/bin/config_generate"
    echo "✅ 默认主机名已改为 $HOSTNAME"
else
    echo "ℹ️ 主机名保持默认 ImmortalWrt"
fi

# ============================================================
# 3. 默认启用 Argon 主题
# ============================================================
mkdir -p "$BASE_FILES/etc/uci-defaults"
cat > "$BASE_FILES/etc/uci-defaults/99-set-argon" << 'EOT'
#!/bin/sh
[ -d "/www/luci-static/argon" ] && {
    uci set luci.main.mediaurlbase='/luci-static/argon'
    uci commit luci
}
exit 0
EOT
chmod +x "$BASE_FILES/etc/uci-defaults/99-set-argon"
echo "✅ 默认 Argon 主题 uci-defaults 已写入"

# ============================================================
# 4. 吉林大学镜像站（ImmortalWrt 24.10.6 / filogic / aarch64_cortex-a53）
# ============================================================
mkdir -p "$BASE_FILES/etc/opkg"
cat > "$BASE_FILES/etc/opkg/distfeeds.conf" << 'EOF'
src/gz immortalwrt_core https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/targets/mediatek/filogic/packages
src/gz immortalwrt_base https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/packages/aarch64_cortex-a53/base
src/gz immortalwrt_luci https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/packages/aarch64_cortex-a53/luci
src/gz immortalwrt_packages https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/packages/aarch64_cortex-a53/packages
src/gz immortalwrt_routing https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/packages/aarch64_cortex-a53/routing
src/gz immortalwrt_telephony https://mirrors.jlu.edu.cn/immortalwrt/releases/24.10.6/packages/aarch64_cortex-a53/telephony
EOF
echo "✅ distfeeds.conf 已替换为吉林大学镜像"

# ============================================================
# 5. 默认启用 ZRAM（128MB + zstd）
# ============================================================
cat > "$BASE_FILES/etc/uci-defaults/98-enable-zram" << 'EOT'
#!/bin/sh
uci set system.@system[0].zram_size_mb='128'
uci set system.@system[0].zram_comp_algo='zstd'
uci commit system
exit 0
EOT
chmod +x "$BASE_FILES/etc/uci-defaults/98-enable-zram"
echo "✅ ZRAM uci-defaults 已写入（128MB / zstd）"

# ============================================================
# 6. 内存优化内核参数
# ============================================================
mkdir -p "$BASE_FILES/etc/sysctl.d"
cat > "$BASE_FILES/etc/sysctl.d/99-memory-optimize.conf" << 'EOF'
vm.vfs_cache_pressure = 200
vm.min_free_kbytes = 8192
vm.swappiness = 80
EOF
echo "✅ sysctl 内存优化参数已写入"

# ============================================================
# 7. 默认 WiFi（2.4G + 5G 同名 SSID）
# ============================================================
mkdir -p "$BASE_FILES/etc/config"
cat > "$BASE_FILES/etc/config/wireless" << 'EOF'
config wifi-device 'radio0'
    option type 'mac80211'
    option path 'platform/soc/18000000.wifi'
    option channel '1'
    option band '2g'
    option htmode 'HE20'
    option disabled '0'

config wifi-iface 'default_radio0'
    option device 'radio0'
    option network 'lan'
    option mode 'ap'
    option ssid 'CMCC-7921'
    option encryption 'psk2'
    option key 'Cy1128724'

config wifi-device 'radio1'
    option type 'mac80211'
    option path 'platform/soc/18000000.wifi+1'
    option channel '36'
    option band '5g'
    option htmode 'HE80'
    option disabled '0'

config wifi-iface 'default_radio1'
    option device 'radio1'
    option network 'lan'
    option mode 'ap'
    option ssid 'CMCC-7921'
    option encryption 'psk2'
    option key 'Cy1128724'
EOF
echo "✅ 默认 WiFi 配置已写入（SSID: CMCC-7920）"

# ============================================================
# 8. quickstart / luci-app-store：剔除磁盘 / RAID / SMART 依赖
#    （不再触碰 USB / 存储内核模块，保留目标默认包）
# ============================================================
# 通用函数：只从 DEPENDS / LUCI_DEPENDS 里剔除 "+pkg" 形式
# 边界: \+pkg 后面必须是空白或行尾，避免子串误伤
strip_deps() {
    local file="$1"; shift
    [ -f "$file" ] || { echo "⚠️ 跳过（不存在）: $file"; return 0; }
    local pkg
    for pkg in "$@"; do
        sed -i -E "s/\\+${pkg}([[:space:]]|\$)/\1/g" "$file"
    done
    # 合并连续空格 + 去行尾空格（不动换行）
    sed -i -E 's/  +/ /g; s/[[:space:]]+$//' "$file"
}

# 8.1 quickstart
if [ -f "package/quickstart/Makefile" ]; then
    # smartmontools-drivedb 必须排在 smartmontools 之前（虽然边界匹配已能防住）
    strip_deps package/quickstart/Makefile \
        mount-utils block-mount lsblk e2fsprogs parted \
        smartmontools-drivedb smartmontools smartd mdadm
    echo "✅ package/quickstart/Makefile 已切除磁盘/RAID/SMART 依赖"
    echo "---- 修改后的 DEPENDS ----"
    grep -n "DEPENDS" package/quickstart/Makefile || true
fi

# 8.2 luci-app-store
if [ -f "package/luci-app-store/Makefile" ]; then
    strip_deps package/luci-app-store/Makefile mount-utils
    echo "✅ package/luci-app-store/Makefile 已切除 mount-utils"
    echo "---- 修改后的 LUCI_DEPENDS ----"
    grep -n "LUCI_DEPENDS" package/luci-app-store/Makefile || true
fi

# ============================================================
# 9. 清理上次打补丁失败残留的 .rej / .orig
# ============================================================
for d in package/quickstart package/luci-app-quickstart package/luci-app-store; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -name "*.rej" -o -name "*.orig" \) -delete
done
echo "✅ 清理 .rej / .orig 补丁残留文件完成"

# ============================================================
# 完成
# ============================================================
echo ""
echo "===== 🎉 所有定制步骤执行完成 ====="
echo "下一步建议:"
echo "  make -j\$(nproc) V=s"
