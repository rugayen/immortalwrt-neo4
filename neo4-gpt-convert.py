#!/usr/bin/env python3
"""把编译产出的 *-sysupgrade.img.gz 的 MBR 分区表原地转换为 GPT。

为什么这样做：
  OpenWrt rockchip 镜像由 gen_image_generic.sh + ptgen 生成 MBR 分区表。
  25.12.2 的 gen_image_generic.sh 虽然支持 GUID(-g) 生成 GPT，但那条路径会
  把 boot 分区改成 FAT 并引入 mkfs.fat/mcopy 等 host 工具依赖。这里改为在镜像
  生成后用 sgdisk --mbrtogpt 原地转换，保留：
    - 两个分区的起止扇区与 ext4 boot 分区（U-Boot 从分区 1 读 kernel.img）
    - 位于 LBA64 / 16384 / 24576 的 Rockchip idbloader / uboot.img / trust.bin
    - gzip 之后附加的 OpenWrt JSON 元数据（append-metadata）
  只改写 LBA0（保护 MBR）、LBA1~33（GPT 表）以及文件末尾（备份 GPT）。
  U-Boot 2025.10 的 nanopi-neo4-rk3399_defconfig 带 CONFIG_CMD_GPT=y，
  EFI_PARTITION / PARTITION_UUIDS 由 BOOT_DEFAULTS 默认启用，故 GPT 下
  `part uuid ...:2 uuid` 生成的 root=PARTUUID= 与内核匹配。

用法：
  python3 neo4-gpt-convert.py <产物目录>            # 转换并校验
  python3 neo4-gpt-convert.py <产物目录> --verify   # 只解析/报告，不转换（本地自检）
"""
import glob
import gzip
import hashlib
import os
import struct
import subprocess
import sys
import zlib

SLACK = 1024 * 1024          # 末尾预留 1MB 给备份 GPT
BOOT_OFFSETS = (32768, 8388608, 12582912)  # LBA64 / 0x4000 / 0x6000


def mbr_partitions(img):
    out = []
    for i in range(4):
        e = img[446 + i * 16:462 + i * 16]
        ptype = e[4]
        start, count = struct.unpack_from("<II", e, 8)
        if ptype and count:
            out.append((start, count, ptype))
    return out


def gpt_partitions(img):
    """读取 GPT 分区条目的 (first_lba, last_lba)。"""
    out = []
    for i in range(128):
        e = img[1024 + i * 128:1024 + (i + 1) * 128]
        if len(e) < 128:
            break
        first, last = struct.unpack_from("<QQ", e, 32)
        if last:
            out.append((first, last))
    return out


def boot_blobs_present(img):
    return all(any(b != 0 for b in img[off:off + 16]) for off in BOOT_OFFSETS)


def inspect(path):
    raw = open(path, "rb").read()
    dec = zlib.decompressobj(31)
    img = dec.decompress(raw) + dec.flush()
    meta = dec.unused_data
    parts = mbr_partitions(img)
    print("  %-72s raw=%d 元数据=%d" % (os.path.basename(path), len(img), len(meta)))
    print("    MBR 分区:", [(s, c, hex(t)) for s, c, t in parts])
    print("    引导 blob:", "存在" if boot_blobs_present(img) else "缺失",
          " GPT签名:", img[512:520] == b"EFI PART")
    return img, meta, parts


def convert(path):
    print("处理:", os.path.basename(path))
    raw = open(path, "rb").read()
    dec = zlib.decompressobj(31)
    img = bytearray(dec.decompress(raw) + dec.flush())
    meta = dec.unused_data
    before = mbr_partitions(bytes(img))
    if len(before) < 2:
        print("  FAIL: 预期至少 2 个 MBR 分区，实际", len(before))
        return 1
    if img[512:520] == b"EFI PART":
        print("  已经是 GPT，跳过")
        return 0
    if not boot_blobs_present(bytes(img)):
        print("  FAIL: 转换前未检测到 Rockchip 引导 blob")
        return 1

    # 扩展文件，给备份 GPT 留出空间（不改变任何已有分区数据）
    img.extend(b"\0" * SLACK)
    tmp = path + ".raw"
    try:
        open(tmp, "wb").write(img)
        r = subprocess.run(["sgdisk", "--mbrtogpt", tmp],
                           capture_output=True, text=True)
        if r.stdout.strip():
            print("  sgdisk:", r.stdout.strip().replace("\n", " | ")[:400])
        if r.returncode != 0:
            print("  FAIL: sgdisk 退出码", r.returncode, r.stderr.strip()[:400])
            return 1
        out = bytearray(open(tmp, "rb").read())
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    # ---- 转换后校验 ----
    if out[512:520] != b"EFI PART":
        print("  FAIL: LBA1 没有 EFI PART 签名")
        return 1
    if out[450] != 0xEE:
        print("  FAIL: LBA0 不是保护 MBR (0xEE)")
        return 1
    after = gpt_partitions(bytes(out))
    if len(after) < len(before):
        print("  FAIL: GPT 分区条目不足", len(after))
        return 1
    for (s, c, _), (first, last) in zip(before, after):
        if first != s or last != s + c - 1:
            print("  FAIL: 分区范围变化 MBR=(%d,%d) GPT=(%d,%d)" % (s, s + c - 1, first, last))
            return 1
    if not boot_blobs_present(bytes(out)):
        print("  FAIL: 转换后引导 blob 被破坏")
        return 1

    # 重新打包：纯 gzip + 原样保留 append-metadata
    packed = gzip.compress(bytes(out), compresslevel=6, mtime=0) + meta
    open(path, "wb").write(packed)
    print("  OK  GPT 分区 %d 个，引导 blob 完好，大小 %.1f MB，sha256=%s" % (
        len(after), len(out) / 1048576, hashlib.sha256(packed).hexdigest()))
    return 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    verify = "--verify" in sys.argv
    d = args[0] if args else "bin/targets/rockchip/armv8"
    files = sorted(glob.glob(os.path.join(d, "*sysupgrade.img.gz")))
    if not files:
        print("NO_SYSUPGRADE_IMAGE in", d)
        return 1
    for f in files:
        if verify:
            inspect(f)
        else:
            rc = convert(f)
            if rc:
                return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
