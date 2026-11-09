#!/usr/bin/env bash
#
# build-immortalwrt-neo4.sh
# ---------------------------------------------------------------------------
# 为 FriendlyARM NanoPi NEO4 (Rockchip RK3399, 1GB RAM) 制作最新 ImmortalWrt
# 卡刷固件（SD 卡 / eMMC 均可启动）。
#
# 重要说明：
#   ImmortalWrt 25.12.2（及所有已发布版本）的 rockchip/armv8 目标里【没有】
#   NanoPi NEO4 的设备定义，官方也没有预编译镜像。本脚本会把 NEO4 的设备定义
#   与 U-Boot 配置“移植”进 ImmortalWrt 源码，然后编译出一张包含 U-Boot 的
#   完整可启动镜像：
#       bin/targets/rockchip/armv8/immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz
#   这个 .img.gz 就是“卡刷固件”，直接刷到 SD 卡或 eMMC 即可启动。
#
# 用法：
#   ./build-immortalwrt-neo4.sh            # 在本机 Linux / WSL2 / Ubuntu 直接编译
#   ./build-immortalwrt-neo4.sh docker     # 打印 Docker 用法（见 Dockerfile）
#   IMMORTALWRT_BRANCH=openwrt-24.10 ./build-immortalwrt-neo4.sh   # 换分支
#
# 环境要求（本机模式）：Ubuntu 22.04+/Debian 12+，x86_64，>=4 核，>=25GB 空闲磁盘，
#   并能访问 github.com。首次编译约 1~3 小时。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 可覆盖的环境变量 ----
IMMORTALWRT_REPO="${IMMORTALWRT_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
IMMORTALWRT_BRANCH="${IMMORTALWRT_BRANCH:-master}"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/immortalwrt}"
JOBS="${JOBS:-$(nproc)}"

# 要加入固件的额外软件包（在“设备基础包”之上）
EXTRA_PACKAGES=(
  luci luci-ssl
  kmod-usb3 kmod-usb-storage kmod-usb-storage-uas
  kmod-brcmfmac brcmfmac-firmware-43430-sdio brcmfmac-nvram-43430-sdio
  wpad-openssl
)

info()  { echo "==> $*"; }
die()   { echo "!! $*" >&2; exit 1; }

# 把 NEO4 的设备定义写进 ImmortalWrt 源码（幂等）
apply_patches() {
  local d="$1"
  cd "$d"

  info "移植 NEO4 设备定义到 rockchip/armv8 ..."
  if grep -q "friendlyarm_nanopi-neo4" target/linux/rockchip/image/armv8.mk; then
    info "  armv8.mk 已包含 NEO4，跳过"
  else
    cat >> target/linux/rockchip/image/armv8.mk <<'EOF'

define Device/friendlyarm_nanopi-neo4
  $(Device/rk3399)
  DEVICE_VENDOR := FriendlyARM
  DEVICE_MODEL := NanoPi NEO4
  # RK3399 采用 Rockchip miniloader 三段式启动（pine64-bin）：idbloader/trust 由
  # arm-trusted-firmware-rockchip 包（PKG_NAME=rkbin，含预编译 DDR/miniloader blob）
  # 生成，U-Boot 自身由 nanopi-neo4-rk3399_defconfig 编译为 -uboot.img。
  # 这与官方 rk3399 设备（nanopi-r4s 等）完全一致。
  BOOT_FLOW := pine64-bin
  # 显式声明与 U-Boot 变体名一致的 UBOOT_DEVICE_NAME，pine64-bin 流程据此 dd
  # $(SOC)-idbloader.bin / $(UBOOT_DEVICE_NAME)-uboot.img / $(SOC)-trust.bin 进镜像。
  UBOOT_DEVICE_NAME := nanopi-neo4-rk3399
  DEVICE_PACKAGES := kmod-brcmfmac brcmfmac-firmware-43430-sdio brcmfmac-nvram-43430-sdio
endef

TARGET_DEVICES += friendlyarm_nanopi-neo4
EOF
  fi

  info "移植 NEO4 的 U-Boot (nanopi-neo4-rk3399) ..."
  if grep -q "nanopi-neo4-rk3399" package/boot/uboot-rockchip/Makefile; then
    info "  uboot-rockchip 已包含 NEO4，跳过"
  else
    # 必须同时完成两件事，且二者都必须在文件末尾的 $(eval $(call BuildPackage/U-Boot))
    # 之前生效：
    #   (a) 把 nanopi-neo4-rk3399 加进 UBOOT_TARGETS —— DUMP 阶段才会为该变体生成包；
    #   (b) 定义 U-Boot/nanopi-neo4-rk3399 变体块 —— 提供 BUILD_DEVICES / ATF / DEFAULT。
    # 关键教训（run#9 失败原因）：绝不能像早期那样用 cat >> 把变体定义追加到文件末尾。
    # 因为末尾那行 $(eval $(call BuildPackage/U-Boot)) 在 Makefile 解析时就执行，若变体
    # 定义在其之后才出现，DUMP 阶段 $(call U-Boot/nanopi-neo4-rk3399) 会取到空定义，包被
    # 建为空壳、InstallDev 不出 $(BUILD_VARIANT)-uboot.img，最终 pine64-bin 流程 dd 打开
    # nanopi-neo4-rk3399-uboot.img 时报 "No such file or directory"。
    # 变体定义经 InstallDev 的无 TPL 分支（loaderimage --pack u-boot-dtb.bin）产出
    # nanopi-neo4-rk3399-uboot.img，正好被 pine64-bin 写入镜像（与官方 nanopi-r4s 一致）。
    cat > /tmp/neo4_uboot_block.txt <<'UBEOF'

define U-Boot/nanopi-neo4-rk3399
  $(U-Boot/rk3399/Default)
  NAME:=NanoPi NEO4
  # RK3399 的 U-Boot/rk3399/Default 仅设 ATF（不含 TPL）：DDR 初始化由 rkbin 的预编译
  # idbloader 提供，ATF(BL31) 由 trusted-firmware-a-rk3399 提供；U-Boot 自身编译为
  # u-boot-dtb.bin，再经 loaderimage 打包成 $(BUILD_VARIANT)-uboot.img。
  BUILD_DEVICES:= \
    friendlyarm_nanopi-neo4
endef

UBEOF
    python3 - <<'PY'
import re
p = "package/boot/uboot-rockchip/Makefile"
s = open(p).read()
if "nanopi-neo4-rk3399" not in s:
    block = open("/tmp/neo4_uboot_block.txt").read()
    # (a) UBOOT_TARGETS：把当前最后一个条目 rock-5c-rk3588s 改为带续行符，并追加新条目
    s = re.sub(r'^(\s*)rock-5c-rk3588s(\s*)$',
               r'\1rock-5c-rk3588s \\\n\1nanopi-neo4-rk3399',
               s, count=1, flags=re.M)
    # (b) 在末尾的 $(eval $(call BuildPackage/U-Boot)) 之前插入变体定义
    marker = "$(eval $(call BuildPackage/U-Boot))"
    s = s.replace(marker, block + marker, 1)
    open(p, "w").write(s)
    print("patched uboot-rockchip/Makefile: added nanopi-neo4-rk3399 variant + UBOOT_TARGETS entry")
else:
    print("uboot-rockchip already patched")
PY
  fi

  # 首次启动配置：LAN 改为 DHCP 客户端，并关闭自身 LAN DHCP 服务器。
  # OpenWrt 会把源码根目录 files/ 原样打进 rootfs；/etc/uci-defaults/*.sh 在
  # config_generate 生成 /etc/config/network、/etc/config/dhcp 之后执行，
  # exit 0 后脚本自动删除（只生效一次，用户之后可自行改回）。
  info "注入首次启动配置：LAN = DHCP 客户端 ..."
  mkdir -p files/etc/uci-defaults
  cat > files/etc/uci-defaults/99-neo4-lan-dhcp <<'EOF'
#!/bin/sh
# NEO4 只有一个网口：默认 LAN 静态 192.168.1.1 + 自带 DHCP 服务器。
# 改为 DHCP 客户端从上级路由器取地址，并关闭自身 LAN DHCP 服务器避免冲突。
# 守卫：config_generate 尚未生成 network.lan 时不写配置，返回 1 让
# uci-defaults 保留本脚本，下次启动再试，避免写出残缺的 network 配置。
if ! uci -q get network.lan >/dev/null 2>&1; then
    exit 1
fi
uci -q set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci -q set dhcp.lan.ignore='1'
# 主机名固定为 NEO4，便于在主路由的 DHCP 租约表里找到它。
uci -q set system.@system[0].hostname='NEO4'
uci commit
exit 0
EOF
  chmod +x files/etc/uci-defaults/99-neo4-lan-dhcp
}

write_config() {
  local d="$1"
  info "写入 .config（目标 rockchip/armv8，设备 nanopi-neo4 + LuCI）..."
  {
    echo "CONFIG_TARGET_rockchip=y"
    echo "CONFIG_TARGET_rockchip_armv8=y"
    echo "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-neo4=y"
    # 双保险：显式选中 NEO4 的 U-Boot 与 ATF 包，确保即使 defconfig 的 DEFAULT
    # 推导有意外，这两个启动加载器包也一定会被构建并安装其产物
    # （rk3399-idbloader.bin / rk3399-trust.bin / -uboot.img）。
    echo "CONFIG_PACKAGE_u-boot-nanopi-neo4-rk3399=y"
    echo "CONFIG_PACKAGE_trusted-firmware-a-rk3399=y"
    for p in "${EXTRA_PACKAGES[@]}"; do
      echo "CONFIG_PACKAGE_${p}=y"
    done
  } > "$d/.config"
}

build_native() {
  info "[native] 工作目录: $WORKDIR"
  # U-Boot 使用 binman，include/u-boot.mk 的 host prereq 会执行
  #   $(STAGING_DIR_HOST)/bin/python3 -c 'import elftools'
  # 缺失会在 make 一开始直接报 "u-boot: Please install the Python3 elftools module"
  # 并退出（CI run#10 失败根因），根本进不了编译。
  if ! python3 -c 'import elftools' 2>/dev/null; then
    die "缺少 pyelftools：请先执行 sudo apt install python3-pyelftools（或 pip3 install pyelftools）"
  fi
  [ -d "$WORKDIR/.git" ] || \
    git clone --depth 1 --branch "$IMMORTALWRT_BRANCH" "$IMMORTALWRT_REPO" "$WORKDIR"

  cd "$WORKDIR"
  info "更新并安装 feeds ..."
  ./scripts/feeds update -a
  # 关键：不要安装 video 源。master 当前快照里 video 源的
  # feeds/video/frameworks/qt5/qt5base/Config.in 存在循环依赖，一旦被装进配置树，
  # make defconfig 会报 "recursive dependency detected" 并中断，导致 U-Boot / ATF 等
  # 依赖 DEFAULT 选中的包无法被选中，最终镜像打包阶段找不到
  # rk3399-idbloader.bin / rk3399-trust.bin。路由器固件只需 base(内置)+packages+luci。
  ./scripts/feeds install packages luci routing telephony

  apply_patches "$WORKDIR"
  write_config "$WORKDIR"

  info "make defconfig ..."
  make defconfig

  info "开始编译（jobs=$JOBS，预计 1~3 小时）..."
  make -j"$JOBS" V=s

  info "编译完成，产物如下："
  ls -lh bin/targets/rockchip/armv8/*nanopi-neo4* || die "未找到产物，请检查上面的编译日志"
  echo
  info "把上面这个 *-squashfs-sysupgrade.img.gz 刷到 SD 卡或 eMMC 即可（见 README.md）。"
}

build_docker() {
  cat <<'EOF'
[docker] 用法：
  1) 构建镜像：  docker build -t neo4-builder .
  2) 运行编译（把当前目录挂进去，产物会落在 ./immortalwrt/bin/...）：
       docker run --rm -it \
         -v "$PWD":/work -w /work \
         neo4-builder ./build-immortalwrt-neo4.sh native
  说明：Docker 容器内已装好全部编译依赖；宿主只需有 Docker 与 ~25GB 空闲空间。
EOF
}

case "${1:-native}" in
  native) build_native ;;
  docker) build_docker ;;
  *) die "未知参数: $1 （可用 native 或 docker）" ;;
esac
