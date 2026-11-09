#!/bin/sh
# 首次启动：把启动盘（SD 卡 / eMMC）上 root 分区之后的剩余空间做成 ext4 数据分区，
# 挂载到 /mnt/emmc，并写入 /etc/config/fstab 持久化。
#
# 设计原则：幂等 + 失败安全
#   - 只在「剩余空间 > 1GB」且「第 3 分区不存在」时创建新分区；
#   - 只对新创建的分区格式化，绝不覆盖已有分区上的数据；
#   - 工具缺失或步骤失败时只记日志，不影响系统启动；
#   - 返回 1 会让 uci-defaults 保留本脚本，下次启动自动重试。
#
# 日志：/tmp/neo4-emmc-data.log（同时写 syslog）

LOG=/tmp/neo4-emmc-data.log
MOUNTPOINT=/mnt/emmc
log() {
    echo "$(date) $*" >> "$LOG"
    logger -t neo4-emmc-data "$*" 2>/dev/null || true
}

# ---- 1) 从内核 cmdline 的 root=PARTUUID= 定位启动盘 ----
partuuid=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline)
if [ -z "$partuuid" ]; then
    log "cmdline 没有 root=PARTUUID，跳过"
    exit 0
fi

rootpart=""
for p in /sys/class/block/*/*/partuuid /sys/class/block/*/partuuid; do
    [ -r "$p" ] || continue
    if [ "$(cat "$p")" = "$partuuid" ]; then
        rootpart=$(basename "$(dirname "$p")")
        break
    fi
done
if [ -z "$rootpart" ]; then
    log "按 PARTUUID=$partuuid 找不到根分区，下次启动重试"
    exit 1
fi

# mmcblk0p2 -> /dev/mmcblk0 ; sda2 -> /dev/sda
case "$rootpart" in
    *p[0-9]) diskname="${rootpart%p*}" ;;
    *)       diskname=$(echo "$rootpart" | sed 's/[0-9]*$//') ;;
esac
disk="/dev/$diskname"
[ -b "$disk" ] || { log "$disk 不是块设备，跳过"; exit 0; }
log "启动盘=$disk 根分区=$rootpart PARTUUID=$partuuid"

# ---- 2) 计算剩余空间 ----
[ -r "/sys/class/block/$rootpart/start" ] || { log "无法读取分区起始扇区"; exit 1; }
start=$(cat "/sys/class/block/$rootpart/start")
size=$(cat "/sys/class/block/$rootpart/size")
total=$(cat "/sys/class/block/$diskname/size" 2>/dev/null)
[ -n "$total" ] || { log "无法读取磁盘总扇区"; exit 1; }
newstart=$((start + size))
remain=$((total - newstart))
# 1GB = 2097152 个 512 字节扇区
if [ "$remain" -le 2097152 ]; then
    log "剩余空间不足 1GB（${remain} 扇区），跳过"
    exit 0
fi
log "root start=$start size=$size total=$total 新分区起点=$newstart 剩余=${remain} 扇区"

# ---- 3) 必要时创建第 3 个分区 ----
p3="${disk}p3"
created=0
if [ ! -b "$p3" ]; then
    if ! command -v parted >/dev/null 2>&1; then
        log "缺少 parted，无法创建分区，跳过"
        exit 0
    fi
    # GPT 用「分区名」，MBR 用「primary」，两者 parted 语法不同
    ptlabel=$(parted -s "$disk" print 2>/dev/null \
        | sed -n 's/^Partition Table:[[:space:]]*//p' | head -1)
    log "分区表类型=${ptlabel:-未知}"
    if [ "$ptlabel" = "gpt" ]; then
        mkparted() { parted -s "$1" mkpart emmc-data ext4 "$2" 100%; }
    else
        mkparted() { parted -s "$1" mkpart primary ext4 "$2" 100%; }
    fi
    if ! mkparted "$disk" "${newstart}s" >>"$LOG" 2>&1; then
        log "parted mkpart 失败，下次启动重试"
        exit 1
    fi
    created=1
    # 通知内核重读分区表（工具可能缺失，失败不致命）
    partx -a "$disk" >>"$LOG" 2>&1 || \
        blockdev --rereadpt "$disk" >>"$LOG" 2>&1 || true
    sleep 2
fi
if [ ! -b "$p3" ]; then
    log "$p3 设备节点尚未出现，下次启动重试"
    exit 1
fi

# ---- 4) 仅对新分区格式化（绝不覆盖已有数据） ----
if [ "$created" = "1" ]; then
    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        log "缺少 mkfs.ext4，分区已创建但未格式化，下次启动重试"
        exit 1
    fi
    if ! mkfs.ext4 -F -L emmc-data "$p3" >>"$LOG" 2>&1; then
        log "mkfs.ext4 失败，下次启动重试"
        exit 1
    fi
    log "已格式化 $p3 为 ext4"
fi

# ---- 5) 写 fstab 并立即挂载 ----
mkdir -p "$MOUNTPOINT"
uci -q set fstab.emmc='mount'
uci -q set fstab.emmc.target="$MOUNTPOINT"
uci -q set fstab.emmc.device="$p3"
uci -q set fstab.emmc.fstype='ext4'
uci -q set fstab.emmc.options='rw,noatime'
uci -q set fstab.emmc.enabled='1'
uci -q set fstab.emmc.enabled_fsck='1'
uci commit fstab
mount -t ext4 -o rw,noatime "$p3" "$MOUNTPOINT" >>"$LOG" 2>&1 || \
    log "本次未挂载成功，block-mount 会在下次启动自动挂载"
log "完成：$p3 -> $MOUNTPOINT（fstab 已持久化）"
exit 0
