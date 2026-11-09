#!/usr/bin/env python3
"""把 OpenWrt sysupgrade 镜像转换成 FriendlyElec eFlasher 可直接使用的纯 gzip 包。

OpenWrt 的 *-sysupgrade.img.gz 是「gzip 数据流 + 尾部 JSON 元数据」格式，
部分 eFlasher 的解压实现不接受尾部数据（gzip -t 会报 trailing garbage，
Python gzip 模块会误当成第二个 member 而抛 BadGzipFile）。这里用 zlib 只取
gzip 流，重新压成标准 gzip，保证任意 eFlasher 版本都能正常解开。

用法: python3 make-eflasher-packages.py <固件目录>
"""
import glob
import gzip
import hashlib
import os
import sys
import zlib


def convert(src, out_dir):
    raw = open(src, "rb").read()
    dec = zlib.decompressobj(31)  # 31 = gzip
    img = dec.decompress(raw) + dec.flush()
    if not dec.eof:
        raise RuntimeError("gzip 流不完整: %s" % src)

    variant = "squashfs" if "squashfs" in os.path.basename(src) else "ext4"
    out = os.path.join(out_dir, "immortalwrt-neo4-%s-eflasher.img.gz" % variant)
    with gzip.open(out, "wb", compresslevel=6) as f:
        f.write(img)

    chk = zlib.decompressobj(31)
    back = chk.decompress(open(out, "rb").read()) + chk.flush()
    ok = (back == img and chk.eof and len(chk.unused_data) == 0)
    print("EFLASHER %-52s %10d bytes  raw=%d  trailing=%d  check=%s  sha256=%s" % (
        os.path.basename(out), os.path.getsize(out), len(back),
        len(chk.unused_data), "OK" if ok else "FAIL",
        hashlib.sha256(open(out, "rb").read()).hexdigest()))
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
