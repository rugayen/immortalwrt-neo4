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
  # NEO4 的 U-Boot defconfig 使用 CONFIG_TPL=y（binman 方式打包 idbloader），
  # 因此用 pine64-img 流程写入合并后的 u-boot-rockchip.bin（而非 pine64-bin 的三段式）。
  BOOT_FLOW := pine64-img
  DEVICE_PACKAGES := kmod-brcmfmac brcmfmac-firmware-43430-sdio brcmfmac-nvram-43430-sdio
endef

TARGET_DEVICES += friendlyarm_nanopi-neo4
EOF
  fi

  info "移植 NEO4 的 U-Boot (nanopi-neo4-rk3399) ..."
  if grep -q "nanopi-neo4-rk3399" package/boot/uboot-rockchip/Makefile; then
    info "  uboot-rockchip 已包含 NEO4，跳过"
  else
    # 1) 把 nanopi-neo4-rk3399 加进 UBOOT_TARGETS 列表（加到列表末尾）
    sed -i 's|^\(  rock-5c-rk3588s\)$|\1 \\\n  nanopi-neo4-rk3399|' \
      package/boot/uboot-rockchip/Makefile
    # 2) 追加 U-Boot 设备块。BUILD_VARIANT 会自动变成 nanopi-neo4-rk3399，
    #    配合 TPL 后由 InstallDev 产出 $(UBOOT_DEVICE_NAME)-u-boot-rockchip.bin，
    #    正好被 pine64-img 流程写入镜像。
    cat >> package/boot/uboot-rockchip/Makefile <<'EOF'

define U-Boot/nanopi-neo4-rk3399
  $(U-Boot/rk3399/Default)
  NAME:=NanoPi NEO4
  # NEO4 的 U-Boot defconfig 启用 CONFIG_TPL=y，需显式提供 RK3399 的 DDR 初始化
  # blob（rk3399_ddr_800MHz_v1.30.bin），否则 binman 打包 u-boot-rockchip.bin 会失败。
  TPL:=$(RK3399_TPL)
  BUILD_DEVICES:= \
    friendlyarm_nanopi-neo4
endef
EOF
  fi
}

write_config() {
  local d="$1"
  info "写入 .config（目标 rockchip/armv8，设备 nanopi-neo4 + LuCI）..."
  {
    echo "CONFIG_TARGET_rockchip=y"
    echo "CONFIG_TARGET_rockchip_armv8=y"
    echo "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-neo4=y"
    for p in "${EXTRA_PACKAGES[@]}"; do
      echo "CONFIG_PACKAGE_${p}=y"
    done
  } > "$d/.config"
}

build_native() {
  info "[native] 工作目录: $WORKDIR"
  [ -d "$WORKDIR/.git" ] || \
    git clone --depth 1 --branch "$IMMORTALWRT_BRANCH" "$IMMORTALWRT_REPO" "$WORKDIR"

  cd "$WORKDIR"
  info "更新并安装 feeds ..."
  ./scripts/feeds update -a
  ./scripts/feeds install -a

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
