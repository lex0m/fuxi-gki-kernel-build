#!/usr/bin/env python3
"""Pack a fuxi (Xiaomi 13) boot image from a raw arm64 Image.

Vendored replacement for AOSP's mkbootimg.py: the build runner's access to
android.googlesource.com is not reliable, so packaging must not depend on
cloning anything.

Layout produced (Android boot header v4, page size 4096, no ramdisk):
  page 0        : boot_img_hdr_v4 (1584 bytes, zero padded to 4096)
  page 1 ..     : kernel Image (padded up to a 4096 boundary)

Usage: pack_bootimg.py --kernel Image [--output boot.img] [--cmdline "..."]
"""
import argparse
import struct
import sys

MAGIC = b"ANDROID!"
PAGE = 4096
HEADER_V4_SIZE = 1584
HEADER_VERSION = 4


def pack(kernel_path, out_path, cmdline):
    with open(kernel_path, "rb") as f:
        kernel = f.read()
    if not kernel:
        sys.exit("pack_bootimg: empty kernel image")

    hdr = bytearray(HEADER_V4_SIZE)
    struct.pack_into("<8s", hdr, 0, MAGIC)          # magic
    struct.pack_into("<I", hdr, 8, len(kernel))     # kernel_size
    struct.pack_into("<I", hdr, 12, 0)              # ramdisk_size
    struct.pack_into("<I", hdr, 16, 0)              # os_version
    struct.pack_into("<I", hdr, 20, HEADER_V4_SIZE)  # header_size
    struct.pack_into("<IIII", hdr, 24, 0, 0, 0, 0)  # reserved[4]
    struct.pack_into("<I", hdr, 40, HEADER_VERSION)  # header_version
    cmd = cmdline.encode()
    if len(cmd) > 1536:
        sys.exit("pack_bootimg: cmdline too long")
    hdr[44:44 + len(cmd)] = cmd                     # cmdline[1536]
    struct.pack_into("<I", hdr, 1580, 0)            # signature_size

    with open(out_path, "wb") as f:
        f.write(hdr)
        f.write(b"\x00" * (PAGE - HEADER_V4_SIZE))
        f.write(kernel)
        pad = (-len(kernel)) % PAGE
        if pad:
            f.write(b"\x00" * pad)

    total = PAGE + len(kernel) + pad
    print("pack_bootimg: %s -> %s (kernel=%d, ramdisk=0, size=%d)"
          % (kernel_path, out_path, len(kernel), total))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--cmdline", default="")
    a = ap.parse_args()
    pack(a.kernel, a.output, a.cmdline)


if __name__ == "__main__":
    main()
