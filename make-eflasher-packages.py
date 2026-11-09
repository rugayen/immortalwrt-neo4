#!/usr/bin/env python3
"""把 OpenWrt sysupgrade 镜像转换成 FriendlyElec eFlasher 可直接使用的纯 gzip 包。

OpenWrt 的 *-sysupgrade.img.gz 是「gzip 数据流 + 尾部 JSON 元数据」格式，
部分 eFlasher 的解压实现不接受尾部数据（gzip -t 会报 trailing garbage，
Python gzip 模块会误当成第二个 member 而抛 BadGzipFile）。这里只取 gzip 流，
重新压成标准 gzip，保证任意 eFlasher 版本都能正常解开。

重要：4GB root 分区的镜像解压后约 4.1GB，**必须流式处理**，
不能像早期版本那样把整个镜像读进内存（会 MemoryError）。
这里一边流式解压、一边流式写 gzip，内存占用恒定在几 MB。

用法: python3 make-eflasher-packages.py <固件目录>
"""
import glob
import gzip
import hashlib
import os
import sys
import zlib

CHUNK = 256 * 1024
MAX_OUT = 4 * 1024 * 1024  # 每次 decompress 的输出上限，保证内存有界


def stream_ungzip_to_writer(src, writer):
    """把 src 的 gzip 流解压，逐块交给 writer；返回解压总字节数。"""
    dec = zlib.decompressobj(31)
    total = 0
    with open(src, "rb") as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            pending = chunk
            while pending and not dec.eof:
                data = dec.decompress(pending, MAX_OUT)
                if data:
                    writer(data)
                    total += len(data)
                pending = dec.unconsumed_tail
            if dec.eof:
                break
        tail = dec.flush()
        if tail:
            writer(tail)
            total += len(tail)
    return total, dec.eof


def convert(src, out_dir):
    variant = "squashfs" if "squashfs" in os.path.basename(src) else "ext4"
    out = os.path.join(out_dir, "immortalwrt-neo4-%s-eflasher.img.gz" % variant)

    with gzip.open(out, "wb", compresslevel=6) as g:
        total, eof = stream_ungzip_to_writer(src, g.write)
    if not eof:
        print("EFLASHER FAIL %s 源 gzip 流不完整" % os.path.basename(out))
        return False

    # 回读校验：流式数一遍字节数，确认完整、无尾部元数据
    back, back_eof = stream_ungzip_to_writer(out, lambda _b: None)
    h = hashlib.sha256()
    with open(out, "rb") as f:
        for c in iter(lambda: f.read(1024 * 1024), b""):
            h.update(c)
    ok = (back == total and back_eof)
    print("EFLASHER %-50s %10d bytes  raw=%d  check=%s  sha256=%s" % (
        os.path.basename(out), os.path.getsize(out), total,
        "OK" if ok else "FAIL", h.hexdigest()))
    return ok


def main(d):
    srcs = sorted(glob.glob(os.path.join(d, "*sysupgrade.img.gz")))
    if not srcs:
        print("NO_SYSUPGRADE_IMAGE in %s" % d)
        return 1
    for src in srcs:
        if not convert(src, d):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "firmware"))
