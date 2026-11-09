# ImmortalWrt NEO4 构建监控报告

**目标**：为 NanoPi NEO4（RK3399 / 1GB RAM / 用户加装 32GB eMMC）编译最新 ImmortalWrt 卡刷固件
`immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz`。

**仓库**：`rugayen/immortalwrt-neo4`（main） · **runner**：GitHub 托管 `ubuntu-22.04`（已瘦身、`-j2`）

**自动闭环规则**（无需人工指令）：
1. 每 30s 轮询 Actions run，记录当前步骤（`watchdog.log`）；
2. 失败 → 下载失败 job 完整日志（`logs/run*_full.log`）+ 抽取关键报错行（`logs/run*_errors.txt`）→ 追加到本报告 → 自动诊断根因 → 修改代码 → 提交推送 → 新 run 自动触发 → 重启监控；
3. 瞬时错误（网络 / TLS / OOM / 磁盘）自动 rerun，最多 2 次；真实编译错误走第 2 步的修复闭环；
4. 成功 → 下载 artifact、解压到 `firmware/`、写入最终产物清单 → 报告闭环结束。

---

## 历次报错与解决方案

### run #7 — `dd` 找不到 `nanopi-neo4-rk3399-u-boot-rockchip.bin`

**报错日志**
```text
dd: failed to open '.../nanopi-neo4-rk3399-u-boot-rockchip.bin': No such file or directory
```

**根因（当时的表层判断）**：设备定义里把 `BOOT_FLOW` 设成 `pine64-img` 并加了 `TPL`，`pine64-img` 流程要求 binman 产出的 `-u-boot-rockchip.bin`；RK3399 走的是 miniloader 三段式，只有设置 TPL（binman）时才会生成该文件。

**解决方案**：`BOOT_FLOW := pine64-bin`（沿用 `Device/rk3399` 默认值），移除 `TPL:=$(RK3399_TPL)`；`U-Boot/nanopi-neo4-rk3399` 去掉 TPL 行，只继承 `$(U-Boot/rk3399/Default)` 的 ATF。
**修复提交**：`371e5f3` → 触发 run #8。
**结果**：run #8 换了一个报错，说明这只是表层症状，未触及真正根因。

### run #8 — `dd` 找不到 `rk3399-idbloader.bin`

**报错日志**
```text
dd: failed to open '.../rk3399-idbloader.bin': No such file or directory
```

**根因（真正根因）**：`./scripts/feeds install -a` 把 `video` feed 拉进配置树，而当前 master 快照的 `feeds/video/frameworks/qt5/qt5base/Config.in:18` 存在 **循环依赖**，导致
```text
feeds/video/frameworks/qt5/qt5base/Config.in:18:error: recursive dependency detected!
```
`make defconfig` 直接中断。于是 `include/u-boot.mk` 里 `DEFAULT := y if TARGET_rockchip_armv8_DEVICE_<device>` 的选择逻辑从未生效，`u-boot-rockchip` / `trusted-firmware-a-rk3399` 都没被选中，rkbin 的 `rk3399-idbloader.bin`、`rk3399-trust.bin` 自然不会生成。日志里这两个包名出现次数均为 0。

**解决方案**：
- `./scripts/feeds install -a` → `./scripts/feeds install packages luci routing telephony`（排除 video feed）；
- `.config` 里显式加 `CONFIG_PACKAGE_u-boot-nanopi-neo4-rk3399=y`、`CONFIG_PACKAGE_trusted-firmware-a-rk3399=y` 双保险。
**修复提交**：`17deead` → 触发 run #9。
**结果**：defconfig 干净跑完，idbloader/trust 成功生成，暴露出下一层问题。

### run #9 — `dd` 找不到 `nanopi-neo4-rk3399-uboot.img`

**报错日志**
```text
dd if=.../rk3399-idbloader.bin ... (235 KB, 成功写入)
dd: failed to open '.../nanopi-neo4-rk3399-uboot.img': No such file or directory
make[3]: *** [Makefile:...: ...] Error 1
```

**根因**：把 `define U-Boot/nanopi-neo4-rk3399` 用 `cat >>` **追加到 `package/boot/uboot-rockchip/Makefile` 文件末尾**，而文件末尾那行 `$(eval $(call BuildPackage/U-Boot))` 在 Makefile 解析时**就立即执行**。见 `include/u-boot.mk`：`BuildPackage/U-Boot` 在 DUMP 阶段遍历 `UBOOT_TARGETS` 并调用 `$(call U-Boot/<variant>)`。定义出现在 eval 之后 → 取到空定义 → 该 uboot 包被建为空壳 → `Build/InstallDev`（无 TPL 分支）不会用 `loaderimage` 产出 `$(BUILD_VARIANT)-uboot.img`。16 万行日志里完全没有该变体的编译记录。

**解决方案**：
- 把 U-Boot 变体定义**插入到 `$(eval …)` 之前**（CI 用 awk、本地脚本用 python3 实现）；`UBOOT_TARGETS` 的 sed 添加保留（它本就在 eval 之前）；
- 设备定义显式声明 `UBOOT_DEVICE_NAME := nanopi-neo4-rk3399`，与变体名、`pine64-bin` 的 dd 文件名对齐。
**修复提交**：`0413be1` → 触发 run #10。
**结果**：run #10 日志中 `CONFIG_PACKAGE_u-boot-nanopi-neo4-rk3399=y` 与 `luci=y` 均保留，u-boot 的 binman prereq 首次被触发，证明本修复生效。

### run #10 — host 依赖 `python3-pyelftools` 缺失（4 分钟即挂）

**报错日志**
```text
Checking 'python3-pyelftools'... failed.
u-boot: Please install the Python3 elftools module
make[3]: *** [include/prereq.mk:9: prereq] Error 1
Package prerequisite check failed.
make: *** [include/toplevel.mk:270: world] Error 2
```

**根因**：`uboot-rockchip/Makefile` 定义 `UBOOT_USE_BINMAN:=1`，`include/u-boot.mk`（29–33 行）的 `TestHostCommand python3-pyelftools` 会执行 `$(STAGING_DIR_HOST)/bin/python3 -c 'import elftools'`。CI 的 apt 依赖清单漏了 `python3-pyelftools`，`make` 在 prereq 阶段就退出，根本没进入编译。同机制下 `python3-setuptools` 检查 ok，说明该 staging host python 读的是系统 dist-packages，apt 安装即可满足。

**解决方案**：
- workflow 依赖安装新增 `python3-pyelftools python3-pip`，加 pip 兜底 + `/usr/bin/python3` 与 PATH python3 双重自检；
- `build-immortalwrt-neo4.sh` 增加 pyelftools 前置自检，`Dockerfile` 同步补齐依赖；
- 修正监控脚本状态解析（旧版 `conclusion` 带前导空格导致 completed 判断恒假、失败不写分析），加 4h 超时；
- `.gitignore` 屏蔽含 PAT 的监控脚本与临时抓取文件。
**附带核实**：主线 U-Boot **v2026.10 含 `configs/nanopi-neo4-rk3399_defconfig`**，变体名可正常配置，不是下一个坑。
**修复提交**：`bbaa483` → 触发 run #11。
**结果**：run #11 第 4 步「安装编译依赖」success（自检为硬校验），正式进入编译。

---

## 当前进度 —— 已完成 ✅

- **run #11**（`42555210554`，commit `bbaa483`）：`completed / success`，编译于 04:39 UTC 结束（总耗时约 1 小时 26 分），步骤 1–9 全部 success。
- 自动闭环 watchdog 自动下载 artifact（id `13650227623`，31.2 MB）并解压到 `firmware/`，闭环结束。
- **本轮没有新增报错**：run #7~#10 的四次报错全部修复后，固件一次编译通过。

## ✅ 构建成功 —— 2026-11-09 04:40 UTC

- **成功 run**：`42555210554`
- **artifact id**：`13650227623`
- **固件目录**：`firmware/`

```text
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-ext4-sysupgrade.img.gz                      17601458 bytes
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz                  15491034 bytes
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4.manifest                                        5102 bytes
```

自动闭环结束：固件已输出到 `firmware/`，可直接刷入 SD 卡或 eMMC。

### 固件完整性校验（本地）

- gzip 流完整（zlib `eof=True`），解压后镜像 **224 MB**；尾部 282 字节为 OpenWrt 标准 JSON 元数据
  （`metadata_version 1.1`），不是损坏——`gzip -t` 的 "trailing garbage ignored" 属正常现象。
- 三段引导**全部写入镜像**（对应 `pine64-bin` 的 dd 偏移）：
  - `idbloader` @ 32 KB：16/16 字节非零；
  - `uboot.img` @ 8 MB：头部 `4c4f414445522020` = `"LOADER  "`（loaderimage 魔数）；
  - `trust.bin` @ 12 MB：头部 `424c3358` = `"BL3X"`（Rockchip trust 魔数）。
  - 这直接证明 run #9 的 `nanopi-neo4-rk3399-uboot.img` 缺失问题已被彻底修复。
- **SHA256**（`...-squashfs-sysupgrade.img.gz`）：
  `805abb90a6f42a7d9d3757cc442f0e5f6c50a54dac8d29ccc0c56a19a5d00e36`
- `manifest` 含 `brcmfmac-nvram-43430-sdio` 等 NEO4 设备包，说明设备定义生效。

### 刷机方法

```bash
# Linux / WSL（先确认 /dev/sdX 是 SD 卡或 eMMC，切勿写错盘）
gzip -dc firmware/immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Windows 可用 balenaEtcher / Rufus 直接选择该 `.img.gz`。推荐 **squashfs** 版（支持 sysupgrade、有 failsafe）；
`ext4` 版适合需要可写根文件系统扩容的场景。

### 通过 FriendlyElec eFlasher 刷入 eMMC

官方 wiki（`Template:BurnLinuxToEMMC-Rockchip`）明确支持第三方固件，示例文件名即
`openwrt-rockchip-armv8_nanopi-ext4-sysupgrade.img.gz`，与本项目产物同类。规则：

- TF 卡写入任意带 `eflasher` 字样的官方固件（网盘 `01_系统固件/02_SD卡刷机固件(SD-to-eMMC)`）；
- 重新插拔后 PC 出现 `FriendlyARM` 盘符，把 `.raw` 或 `.gz` 结尾的镜像复制进去
  （`.img` 需改名为 `.raw`）；
- 编辑卡上 `eflasher.conf`，设 `autoStart=<你的文件名>`；上电即自动烧写，看 LED 进度；
- 烧完**弹出 SD 卡**，板子自动重启并从 eMMC 启动。
- 亦可用方法 2：FriendlyWrt SD 卡启动 → 系统 → eMMC 刷机助手 → 选择文件 → 上传并烧写（支持 .gz/.img/.tgz/.zip）。

为兼容 eFlasher 的解压实现，已把 sysupgrade 包尾部 282 字节 JSON 元数据去掉，重新压成纯 gzip：
`firmware/immortalwrt-neo4-squashfs-eflasher.img.gz` (14.78 MB, SHA256 `084a9f37...`)、
`firmware/immortalwrt-neo4-ext4-eflasher.img.gz` (16.82 MB, SHA256 `c0b9edec...`)，解压均为 224 MB、尾部 0 字节。

镜像为 MBR 两分区（boot 16MB @32MB、root 160MB @64MB），`boot.scr` 使用
`root=PARTUUID=${uuid}` 与 U-Boot 动态 `${devtype} ${devnum}`，未硬编码 SD 设备号，
因此整盘写入 eMMC 后仍可正常挂载根文件系统。

注意：刷写会清空 eMMC 全部数据；镜像仅 224 MB，32GB eMMC 剩余空间需启动后另行扩容；
若刷后 SD 卡不再能启动 eFlasher（eMMC 上的 U-Boot 抢先引导），按住 Mask 键上电进入 Maskrom，
用 RKDevTool 执行 EraseAll 擦除 eMMC 即可恢复。

---

## 功能变更：LAN 默认改为 DHCP 客户端（13:07 用户确认）

- **需求**：NEO4 只有一个网口，OpenWrt 默认 `LAN = 静态 192.168.1.1 + 自带 DHCP 服务器`；
  改为作为 **DHCP 客户端**从上级路由器自动获取 IP。
- **用户选择**：① 重新编译内置 DHCP 的新固件（而非只给刷机后命令）；② **关闭**自身 DHCP 服务器。
- **实现**：CI 与本地脚本在编译前注入 `files/etc/uci-defaults/99-neo4-lan-dhcp`
  （OpenWrt 把源码根 `files/` 原样打进 rootfs）。脚本在首次启动、config_generate 生成
  `/etc/config/network`、`/etc/config/dhcp` 之后执行：
  ```sh
  uci -q set network.lan.proto='dhcp'
  uci -q delete network.lan.ipaddr
  uci -q delete network.lan.netmask
  uci -q set dhcp.lan.ignore='1'
  uci -q set system.@system[0].hostname='NEO4'
  uci commit
  exit 0     # 成功后 uci-defaults 自动删除脚本，只生效一次
  ```
  另加守卫：`network.lan` 尚未生成时 `exit 1` 保留脚本、下次启动重试，避免写出残缺配置。
- **本地验证**：模拟 GitHub Actions 的 `run: |` 缩进剥离后，生成的脚本 `#!/bin/sh` 在首行、
  `bash -n` 通过、权限可执行。
- **产物隔离**：新固件输出到 `firmware-dhcp/`，不覆盖上一版静态 IP 固件。
- **使用注意**：刷完设备没有固定 IP，需在主路由 DHCP 租约表里按主机名 **NEO4** 查找
  （或用串口调试）。串口始终可用，也可随时用 uci 改回静态地址。

## 功能变更：LuCI 界面默认简体中文（13:18 用户追加）

- **查证**：ImmortalWrt 的 luci feed 中 po 目录为 `zh_Hans`/`zh_Hant`，但
  `luci.mk` 里 `LUCI_LC_ALIAS.zh_Hans=zh-cn`，因此包名仍是 **`luci-i18n-base-zh-cn`**。
  LuCI `modules/luci-base/ucode/dispatcher.uc` 读取 `luci.main.lang`，并把 `_` 替换成 `-`
  后加载 `*.zh-cn.lmo`；默认配置为 `option lang 'auto'`。
- **实现**：
  - `.config` 增加 `CONFIG_PACKAGE_luci-i18n-base-zh-cn=y`（本地脚本 `EXTRA_PACKAGES` 同步）；
  - uci-defaults 增加 `uci -q set luci.main.lang='zh_cn'`，随 `uci commit` 一并落盘。
  - 值必须写 `zh_cn`（不是 `zh-cn`、`zh_Hans`）。
- 上一版仅 DHCP 的 run `42566061713` 已取消，避免产出两个版本；中文与 DHCP 合并进同一次编译。
- 闭环补强：新增 `make-eflasher-packages.py`，watchdog 成功后自动生成去尾部元数据的
  eFlasher 专用包，并写入报告清单（此前该步骤需人工执行）。

## 版本切换 + IPv6（13:28 用户追加）

- **基础版本**：从 `master` 快照改为固定发布 tag **`v25.12.2`**
  （`git clone --depth 1 --branch v25.12.2`；feeds.conf.default 里的 packages/luci/routing/
  telephony/video 也锁定到该版本对应 commit，构建可复现）。
- **兼容性核对**（直接拉取 `v25.12.2` 的上游源码逐项比对，结论：现有 NEO4 补丁全部不用改）：
  - `target/linux/rockchip/image/armv8.mk`：`Device/rk3399` 默认 `BOOT_FLOW := pine64-bin`；
  - `target/linux/rockchip/image/Makefile`：`pine64-bin` 的 dd 偏移仍是 64 / 16384 / 24576，
    `UBOOT_DEVICE_NAME` 推导仍在第 77 行；
  - `package/boot/uboot-rockchip/Makefile`：`UBOOT_TARGETS` 末项仍是 `rock-5c-rk3588s`
    （sed 锚点有效），`$(eval $(call BuildPackage/U-Boot))` 在第 625 行，
    `Build/InstallDev` 无 TPL 分支仍用 `loaderimage` 产 `$(BUILD_VARIANT)-uboot.img`，
    `UBOOT_USE_BINMAN:=1` 仍在（pyelftools 依赖继续保留）；
  - **唯一差异**：U-Boot 版本 `2025.10`（master 是 `2026.10`）；已确认 U-Boot v2025.10
    的 `configs/nanopi-neo4-rk3399_defconfig` 存在；
  - `atf-version.mk` 里 `RK3399_ATF/TPL/LOADER` blobs 齐全；
  - 该版本 luci feed（固定 commit `d6167ea…`）仍是 `LUCI_LC_ALIAS.zh_Hans=zh-cn`，
    故中文包名 `luci-i18n-base-zh-cn` 与 `zh_cn` 语言值继续有效。
- **IPv6 自动获取**（OpenWrt 官方 Bridged AP 方案）：uci-defaults 创建 `lan6` 接口
  `proto=dhcpv6`、`device=@lan`、`reqaddress=try`、`reqprefix=no`、`lan.delegate=0`；
  并关闭本机 LAN 上的 `dhcpv6/ra/ndp` 服务（`disabled`），全部交给上级路由，避免冲突。
  上游只发 RA 时也能靠 **SLAAC + RDNSS** 获得 IPv6 地址与 DNS。
  另注入 `files/etc/sysctl.d/99-neo4-ipv6.conf` 设 `accept_ra=2`，保证开启 IPv6 转发时
  SLAAC 仍生效；`.config` 显式选中 `CONFIG_PACKAGE_odhcp6c=y`。
- 本轮把 DHCP + 中文 + 25.12.2 + IPv6 合并为**一次编译**，避免产出多个中间版本。

## 磁盘空间：软件包 4GB + eMMC 剩余空间挂载（13:33 用户追加）

- **软件包空间 4GB**：`.config` 增加 `CONFIG_TARGET_ROOTFS_PARTSIZE=4096`（单位 MB）。
  该值决定 root 分区大小；squashfs 只读部分之外的空间由 fstools 作为 overlay，
  即「可安装软件包 / 保存配置」的可用空间约 4GB（默认仅约 160MB）。
  镜像 gzip 后仍然很小（零填充高压缩率），但刷写时会写入约 4.1GB。
- **eMMC 剩余空间挂载**：新增 `neo4-emmc-data.uci-defaults.sh` 模板，CI 与本地脚本
  共用同一份，注入为 `files/etc/uci-defaults/99-neo4-emmc-data`。首次启动时：
  1. 从 `/proc/cmdline` 的 `root=PARTUUID=` 定位启动盘（SD 卡或 eMMC 都适用）；
  2. 读 sysfs 算出 root 分区结束扇区，剩余空间 > 1GB 才继续；
  3. `parted -s ... mkpart primary ext4 <start>s 100%` 创建第 3 分区；
  4. **只对新创建的分区**执行 `mkfs.ext4 -F -L emmc-data`（绝不覆盖已有数据）；
  5. 写 `/etc/config/fstab`（命名段 `emmc`）挂载到 **`/mnt/emmc`**，并立即挂载一次。
  - 幂等 + 失败安全：工具缺失或步骤失败只写 `/tmp/neo4-emmc-data.log`，不影响启动；
    返回 1 时 uci-defaults 会保留脚本，下次启动重试。
- 依赖包已在 25.12.2 中核实存在：`parted`（锁定的 packages feed `utils/parted`）、
  `e2fsprogs` 与 `block-mount`（主仓库）、`kmod-fs-ext4`。
- 最终这一版合并：**v25.12.2 + LAN DHCP + LuCI 中文 + IPv6 + 4GB 软件包空间 + eMMC 剩余空间挂载**。

## 分区表改为 GPT（13:44 用户追加）

- **启动链可行性已核实**：U-Boot 2025.10 的 `nanopi-neo4-rk3399_defconfig` 明确带
  `CONFIG_CMD_GPT=y`；`disk/Kconfig` 里 `EFI_PARTITION` 默认 `y if BOOT_DEFAULTS`、
  `PARTITION_UUIDS` 默认 `y if EFI_PARTITION`，因此 GPT 下 `part uuid ...:2 uuid`
  生成 `root=PARTUUID=` 与内核匹配，U-Boot 也能从分区 1 读取 `kernel.img`。
- **实现方式**：25.12.2 的 `gen_image_generic.sh` 虽可用 `GUID` 让 `ptgen -g` 直接出 GPT，
  但那条路径会把 boot 分区改成 FAT 并引入 `mkfs.fat`/`mcopy` host 依赖。改为编译后
  用 **`sgdisk --mbrtogpt` 原地转换**（新增 `neo4-gpt-convert.py`，CI/本地脚本共用）：
  - 保留两个分区的起止扇区与 **ext4 boot 分区**；
  - 保留 gzip 之后附加的 OpenWrt JSON 元数据（`append-metadata`）；
  - 只改写 LBA0 保护 MBR、LBA1–33 GPT 表、文件末尾备份 GPT；
  - LBA64 / 16384 / 24576 的 Rockchip idbloader / uboot.img / trust.bin **不受影响**。
- **转换后强校验**（任一不符即让 CI 失败，避免产出无法启动的镜像）：
  `EFI PART` 签名、保护 MBR 的 `0xEE`、GPT 分区起止 LBA 与原 MBR 一致、三段引导 blob 完好。
- runner 依赖新增 `gdisk`（提供 sgdisk），Dockerfile 同步；本地脚本编译后自动调用转换。
- `neo4-emmc-data.uci-defaults.sh` 同步适配：检测 `Partition Table: gpt` 后用
  `parted mkpart emmc-data ext4 ...`（MBR 才用 `primary`），`100%` 保留 GPT 末尾备份表。
- 上一版 run `42568491957` 已取消，GPT 与其余配置合并为一次编译。
- run 42568491957 结束，结论 cancelled（非成功/失败）

## ✅ 构建成功 —— 2026-11-09 07:24 UTC

- **成功 run**：`42569562442`
- **artifact id**：`13656830788`
- **固件目录**：`firmware-dhcp/`

```text
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-ext4-sysupgrade.img.gz                      21173839 bytes
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4-squashfs-sysupgrade.img.gz                  19083340 bytes
immortalwrt-rockchip-armv8-friendlyarm_nanopi-neo4.manifest                                        5813 bytes
```

自动闭环结束：固件与 eFlasher 专用包已输出到 `firmware-dhcp/`，可直接刷入 SD 卡或 eMMC。

### 交付前校验与一处后处理修复（15:24）

- **CI 结论**：run `42569562442` `completed/success`，步骤 #9 编译、#10 **分区表转换为 GPT**、
  #11 上传产物全部 success。
- **发现并修复**：首次 watchdog 生成 eFlasher 包时，`make-eflasher-packages.py` 把 4GB 镜像
  一次性解压进内存导致 `MemoryError`，包实际未生成（脚本误报"已生成"）。已改为
  **流式解压 + 流式写 gzip**（内存恒定几 MB），同时给 watchdog 加上返回码判断，避免再误报。
  该修复只影响本地后处理，不影响已编译固件，故用 `[skip ci]` 提交，不触发新构建。
- **最终 4 个镜像文件逐项校验通过**（流式扫描，保留前 16MB 与末尾 64KB）：

  | 检查项 | 结果 |
  |---|---|
  | 保护 MBR 类型 | `0xEE` |
  | GPT 主签名 / 末尾备份 GPT | 均存在 |
  | GPT 分区 1 | `(65536, 98303)` = boot 16MB @32MB |
  | GPT 分区 2 | `(131072, 8519679)` = root **4096MB** @64MB |
  | idbloader @32KB | 有数据 |
  | uboot.img @8MB | `4c4f414445522020` = `"LOADER  "` |
  | trust.bin @12MB | `424c3358` = `"BL3X"` |
  | 解压后镜像 | 4161 MB（约 4.06GB） |
  | sysupgrade 尾部元数据 | 580 字节 JSON 保留 |
  | eFlasher 专用包尾部 | 0 字节（纯 gzip） |

- **eFlasher 专用包 SHA256**：
  - `immortalwrt-neo4-squashfs-eflasher.img.gz` = `172479b0f1e71fbf485de8dc12496b20b65a0dc5b04a48c97b4d58b3a997e156`
  - `immortalwrt-neo4-ext4-eflasher.img.gz` = `1d8cde03fe0f717d028a0fdd0b49ea7301fd183e18076ca9eda14b0d3168502a`

> 注意：4GB root 分区使刷写时需实际写入约 4.06GB，比早期 224MB 版本慢；
> eFlasher 的 TF 卡放 `.img.gz` 压缩文件（约 19MB）即可，FAT32 单文件限制不受影响。

## 用户反馈：原生 sysupgrade 包不要用于整盘刷写（16:51）

- 反馈：用原生 `*-squashfs-sysupgrade.img.gz` 刷机出现「**爆闪**」（LED 异常闪烁 / 启动失败）。
- 原因：`sysupgrade.img.gz` = gzip 流 + **580 字节 JSON 元数据尾部**，是 OpenWrt 给
  `sysupgrade` 命令用的升级载荷，**不是 eFlasher 的整盘镜像**。eFlasher 解压时遇到尾部
  数据可能报错或写入不完整，导致引导区损坏 → 板子起不来、LED 爆闪。
  这正是当初单独生成 `*-eflasher.img.gz`（纯 gzip、尾部 0 字节）的原因。
- **交付口径修正**：整盘刷写（SD 卡 / eMMC / eFlasher）**只使用 `*-eflasher.img.gz` 专用包**；
  原生 sysupgrade 包仅保留供已运行系统里执行 `sysupgrade` 升级，不再作为刷机交付物。
- 桌面上的原生 sysupgrade 副本已按用户要求移入回收站（SHA256 与项目源文件一致，
  项目源文件 `firmware-dhcp/` 内仍完好，可随时恢复）。
- 若已用原生包刷坏：断电 → 按住 **Mask** 键上电进入 Maskrom → RKDevTool 执行
  `EraseAll` 擦除 eMMC → 再用 eFlasher 专用包重刷。

## 任务：固化 10.10.10.74 运维手册最终态并重新编译（2026-11-10 01:58）

### 分析结论

引用的 `10.10.10.74-ops-handbook-20261110.zip` 是**同一台 NEO4 / ImmortalWrt 25.12.2 单臂旁路由**
刷完本仓库固件后的完整落地记录（21 个文件，含 `machine-profile.yaml`、`snapshots/*.txt`、
`docs/01~04`、6 个幂等脚本）。其 `docs/03` 第 4 节明确列出「重刷固件后必须重做的 7 件事」，
`README` 第 6 节也把「重刷镜像会覆盖 GPT 与 overlay 中装的包」列为遗留风险。
=> 用户要的是：**把这些运行时改动固化进固件**，重刷后开机即达手册记录的最终状态。

事实来源按手册约定：`machine-profile.yaml` > `snapshots/*.txt` > `docs/04` > `docs/02`。

### 固化清单（逐项对应 docs/03 重建清单）

| 手册项 | 固化方式 |
|---|---|
| network（br-lan/eth0、lan=dhcp+ip6assign 60+delegate 0、lan6 dhcpv6 含 norelease/sendclientid/multipath） | `files/etc/config/network`（快照原文） |
| dhcp（dnsmasq 全参数、dhcp.lan ignore=1 / dhcpv6/ra/ndp disabled、odhcpd maindhcp=0） | `files/etc/config/dhcp` |
| firewall（仅 lan zone、defaults input=REJECT/forward=REJECT、flow offload、fullcone=0、无 NAT） | `files/etc/config/firewall` |
| wireless（AP6212 radio0、SSID ImmortalWrt、psk2+ccmp、channel 1 / 2g / HT20 / CN、disabled=0） | `files/etc/config/wireless` |
| apk 源修复（移除 25.12.2 未发布的 video feed，vsean 镜像；官方源备份同步） | `files/etc/apk/repositories.d/distfeeds.list{,.bak}` |
| `/opt` 24.8G 挂载 | `files/etc/rc.local` + `99-neo4-emmc-opt`（p3、label opt_data、mkfs.ext4 -m 0；脚本按实际设备名动态重写 rc.local，兼容 SD/eMMC） |
| 无线固件 | `.config` 显式选 `cypress-firmware-43430-sdio`（PROVIDES 虚拟名不可靠）+ `99-neo4-wireless-firmware` 补两条 NVRAM 软链 |
| 主机名 NEO4 / LuCI 中文 | `99-neo4-firstboot`（uci-defaults，带守卫） |
| SSH 免密 | `files/etc/dropbear/authorized_keys`（本机 `~/.ssh/id_ed25519.pub`） |
| IPv6 SLAAC | `files/etc/sysctl.d/99-neo4-ipv6.conf`（accept_ra=2） |

**实现方式**：OpenWrt 把源码根 `files/` 原样打进 rootfs，故 workflow 与本地脚本统一改为
`cp -a files/.` + `chmod`，删掉了原先冗长的内联 heredoc；CI 与本地共用同一份配置，零转录误差
（配置原文直接由 zip 的 snapshots 提取）。

### ⚠️ 敏感信息提示（已随配置进入公开仓库）

- AP 密码 `00000000`（用户指定测试密码，极弱）写在 `files/etc/config/wireless`；
- SSH **公钥**（非私钥）写在 `files/etc/dropbear/authorized_keys`；
- 手册记录设备 root 为空密码登录、有公网 IPv6 地址且未加主动入站阻断 —— 这些是用户明确
  选择「保持不变」的现状，本次未擅自加固。
- 若设备暴露公网，建议换强 AP 密码并限制管理面入站。

### 交付口径

沿用之前全部要求：v25.12.2 + GPT + 4GB 软件包空间 + LuCI 中文 + IPv6 + 只交付
`*-eflasher.img.gz` 专用包（原生 sysupgrade 包不作为交付物）。编译成功后由 watchdog
自动下载、生成 eFlasher 包，并复制到 `C:/Users/rugayen/Desktop`。
