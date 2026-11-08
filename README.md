# NanoPi NEO4 · 最新 ImmortalWrt 卡刷固件制作套件

基于 FriendlyELEC Wiki（NanoPi NEO4）与 ImmortalWrt 源码整理、移植并打包的一套**可复现构建方案**，
用于给你的 **NanoPi NEO4（Rockchip RK3399，1GB RAM，已自行加装 32GB eMMC）** 制作最新的 ImmortalWrt 卡刷固件。

> ⚠️ 重要前提：截至 ImmortalWrt 25.12.2（以及所有已发布版本），官方 **rockchip/armv8 目标里没有 NanoPi NEO4 的设备定义**，
> 官网固件选择器对 NEO4 返回 “No model found”，也没有预编译镜像。OpenWrt 主线同样未合入 NEO4。
> 因此本套件把 NEO4 的设备定义 + U‑Boot 配置**移植**进 ImmortalWrt 源码后再编译——这是一个社区移植版，不是官方签名构建。

---

## 1. 硬件要点（来自官方 Wiki）

| 项目 | 说明 |
| --- | --- |
| SoC | Rockchip RK3399（双核 A72 + 四核 A53） |
| 内存 | 1GB DDR3-1866（**偏紧**，仅够跑轻量路由） |
| 启动 | 原厂无板载 eMMC，**你已加装 32GB eMMC** → 现在可走 **SD 卡 或 eMMC** 启动 |
| 网络 | 1 × 原生千兆以太网（RK3399 GMAC，驱动已内置） |
| 无线 | 板载 AP6212（BCM43430，2.4G 仅 SDIO Wi‑Fi/BT） |
| 接口 | 1×USB3.0、2×USB2.0、HDMI、MIPI‑CSI、40pin GPIO、RTC |
| 供电 | 5V/3A，Type‑C 或 40pin 第 2/4 脚 |

> eMMC 启动意味着：固件是一张**完整磁盘镜像**（含 U‑Boot + 内核 + 根文件系统），
> 无论刷到 SD 还是 eMMC，刷写方式一致。

---

## 2. 你会得到什么

构建成功后，在 `bin/targets/rockchip/armv8/` 下生成：

```
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz
```

- 这是一张**已经包含 U‑Boot 的完整可启动镜像**（RK3399 的 `BOOT_FLOW := pine64-bin` 会把
  idbloader / u-boot / trust 直接打进镜像）。
- 直接刷到 **SD 卡或 eMMC** 即可首次启动，无需再单独烧 U‑Boot。
- 文件名里的 `sysupgrade` 只是 OpenWrt/ImmortalWrt 的命名习惯；对 rockchip 而言它就是卡刷镜像。

> 默认管理地址 `192.168.1.1`，Web 界面 LuCI 已包含（http://192.168.1.1）。

---

## 3. 三种构建方式（任选其一）

### A. 本机 / WSL2 / Ubuntu 原生编译（最推荐）

要求：Ubuntu 22.04+ 或 Debian 12+，x86_64，≥4 核，≥25GB 空闲磁盘，可访问 github.com。

```bash
sudo apt-get update
sudo apt-get install -y build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses5-dev libssl-dev python3 python3-distutils \
  python3-setuptools rsync unzip zlib1g-dev file wget ccache

cd immortalwrt-neo4
chmod +x build-immortalwrt-neo4.sh
./build-immortalwrt-neo4.sh            # 默认克隆 master 分支并编译
```

想换分支/版本：`IMMORTALWRT_BRANCH=master ./build-immortalwrt-neo4.sh`
（稳定版可用 `openwrt-24.10` 等已存在的分支名；master 即“最新”）。

首次编译约 1~3 小时，产物在 `immortalwrt/bin/targets/rockchip/armv8/`。

### B. Docker（不想污染本机环境）

```bash
cd immortalwrt-neo4
docker build -t neo4-builder .
docker run --rm -it -v "$PWD":/work -w /work neo4-builder \
  ./build-immortalwrt-neo4.sh native
```
产物落在 `./immortalwrt/bin/targets/rockchip/armv8/`。

### C. GitHub Actions（免费云端构建，无需本地 Linux）

1. 把本目录（`immortalwrt-neo4/`）推到你自己的 GitHub 仓库；
2. 仓库里创建 `.github/workflows/build-neo4.yml`（本套件已提供）；
3. 在仓库 **Actions → “Build ImmortalWrt for NanoPi NEO4” → Run workflow**；
4. 跑完后在 **Artifacts** 里下载 `immortalwrt-neo4` 压缩包，解出的就是 `.img.gz`。

> 注意：GitHub 托管 runner 仅 ~7GB 内存 / ~14GB 磁盘，完整编译可能内存/磁盘不足而失败。
> 失败时请改用**自托管 runner**（建议 16GB+ 内存、30GB+ 磁盘）或一台便宜的 VPS。

---

## 4. 刷写固件（卡刷）

把上面的 `*-squashfs-sysupgrade.img.gz` 解压得到 `.img`，再刷写。

### 刷到 SD 卡（最常用，首次启动推荐）
- Windows：用 [balenaEtcher](https://www.balena.io/etcher/) 或 Rufus 选择 `.img` 写入 SD 卡；
- Linux/macOS：`xzcat xxx.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`
  （`/dev/sdX` 换成你的读卡器设备，**务必确认别写错盘**）。

插卡上电即可从 SD 启动。

### 刷到你加装的 32GB eMMC
三选一：

1. **USB eMMC 读卡器**（最简单）：把 eMMC 模块拔下插读卡器，按上面的 SD 卡方式直接 `dd`/`Etcher` 写入，再装回板子。
2. **先 SD 启动再写 eMMC**（无须额外硬件）：
   ```bash
   # 在已经 SD 启动的 NEO4 上，把 .img 传到板子后执行：
   xzcat immortalwrt-*-nanopi-neo4-squashfs-sysupgrade.img.gz | dd of=/dev/mmcblk1 bs=4M conv=fsync
   # /dev/mmcblk1 即 eMMC 设备；写完后拔掉 SD 卡，重启即从 eMMC 启动
   ```
3. **RKDevTool / Maskrom（Windows）**：进入 Maskrom 模式后用 FriendlyELEC 的 `rk3399` 烧写工具写入——适合需要 vendor loader 的场景，普通卡刷用不到。

> 启动优先级：检测到 SD 卡时优先从 SD 启动，否则从 eMMC 启动。两块都刷了镜像时，拔掉 SD 才会走 eMMC。

---

## 5. 首次启动与配置

1. 网线接 NEO4 的 **千兆网口** ↔ 你的电脑/路由器；
2. 浏览器打开 `http://192.168.1.1` → LuCI；
3. 在 **System → Administration** 设置 root 密码（ ImmortalWrt 默认无密码）；
4. 网络 → 接口：WAN 接外网、LAN 做内网；NEO4 只有 1 个网口，按需用 VLAN / USB 网卡扩展；
5. 无线：AP6212 为 2.4G 仅 Wi‑Fi，可在 **网络 → 无线** 中启用；固件已带 `brcmfmac` 与 43430 固件，AP 模式需 `wpad`（已包含）。
   若 Wi‑Fi 不认 NVRAM，可到 **系统 → 软件** 安装 `brcmfmac-nvram-43430-sdio` 并重启。

---

## 6. 移植做了什么（技术细节）

`build-immortalwrt-neo4.sh` 的 `apply_patches()` 在克隆后的源码上自动完成两处修改：

1. **`target/linux/rockchip/image/armv8.mk`** 追加设备（不写 `DEVICE_DTS`/`UBOOT_DEVICE_NAME`，
   由 rockchip 的 `Device/Default` 自动推导为 `DEVICE_DTS = rk3399-nanopi-neo4`、
   `UBOOT_DEVICE_NAME = nanopi-neo4-rk3399`，对应主线内核 DTS 与 U‑Boot defconfig）：
   ```makefile
   define Device/friendlyarm_nanopi-neo4
     $(Device/rk3399)
     DEVICE_VENDOR := FriendlyARM
     DEVICE_MODEL := NanoPi NEO4
     DEVICE_PACKAGES := kmod-brcmfmac brcmfmac-firmware-43430-sdio brcmfmac-nvram-43430-sdio
   endef
   TARGET_DEVICES += friendlyarm_nanopi-neo4
   ```
2. **`package/boot/uboot-rockchip/Makefile`** 把 `nanopi-neo4-rk3399` 加进 `UBOOT_TARGETS` 并追加 U‑Boot 块，
   使其使用主线 U‑Boot 的 `nanopi-neo4-rk3399_defconfig` 编译出 `nanopi-neo4-rk3399-uboot.img`。

其余（内核 DTS、ATF、idbloader/trust 等）均由 ImmortalWrt 既有 RK3399 构建链提供，与 NanoPC‑T4 / NanoPi‑R4S 同源。

---

## 7. 已知限制 / 注意事项

- **1GB 内存偏紧**：够跑基础路由 + LuCI，不建议再装 Docker / 大量插件；需要多插件可关掉无关服务。
- **非官方移植**：未经 ImmortalWrt 官方硬件验证；建议先刷 SD 卡测试，确认能启动、网口/USB/Wi‑Fi 正常后再写 eMMC。
- **Wi‑Fi**：板载 AP6212 仅 2.4G，性能一般；主打有线路由时建议把无线当备用。
- **内核版本**：跟随你选择的分支（master 较新、驱动更全；稳定版更保守）。如某分支 U‑Boot 列表末尾不是
  `rock-5c-rk3588s`，脚本里的 `sed` 锚点需相应调整（或手动把 `nanopi-neo4-rk3399` 加进 `UBOOT_TARGETS`）。
- **升级**：后续可在 LuCI 里用同设备生成的 `sysupgrade` 镜像在线升级（会保留配置）。

---

## 8. 文件清单

| 文件 | 作用 |
| --- | --- |
| `build-immortalwrt-neo4.sh` | 一键克隆 + 移植 + 配置 + 编译 |
| `Dockerfile` | 编译环境镜像（仅装依赖） |
| `.github/workflows/build-neo4.yml` | GitHub Actions 云端构建 |
| `README.md` | 本说明 |
