#!/usr/bin/env python3
"""把 KSU_VERSION / KSU_PACKAGE_NAME 固定进 SukiSU Nova 的 Kbuild。

离线 in-tree 构建时 Kbuild 会退化成 30000 / 旧包名，导致管理器提示版本不匹配。
用法：patch_ksu_version.py <Kbuild 路径> <version> <package_name>
"""
import re
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: patch_ksu_version.py <Kbuild> <version> <package_name>", file=sys.stderr)
        return 2
    path, version, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
    src = open(path, "r", encoding="utf-8").read()
    lines = src.splitlines()

    version_re = re.compile(r"^\s*KSU_VERSION\s*[:?]?=.*$")
    pkg_re = re.compile(r"^\s*KSU_PACKAGE_NAME\s*[:?]?=.*$")
    cc_version_re = re.compile(r"^\s*ccflags-y\s*\+=\s*-DKSU_VERSION=")
    cc_pkg_re = re.compile(r"^\s*ccflags-y\s*\+=\s*-DKSU_PACKAGE_NAME=")

    out, has_ver, has_pkg = [], False, False
    for line in lines:
        if version_re.match(line):
            out.append(f"KSU_VERSION := {version}")
            has_ver = True
        elif pkg_re.match(line):
            out.append(f"KSU_PACKAGE_NAME ?= {pkg}")
            has_pkg = True
        else:
            out.append(line)

    def insert_before(predicate, newline):
        global out
        for i, line in enumerate(out):
            if predicate(line):
                out.insert(i, newline)
                return True
        return False

    if not has_ver:
        if not insert_before(cc_version_re.match, f"KSU_VERSION := {version}"):
            print("[patch_ksu_version] 找不到 KSU_VERSION 定义位置，Kbuild 结构可能已变化", file=sys.stderr)
            return 1
    if not has_pkg:
        if not insert_before(cc_pkg_re.match, f"KSU_PACKAGE_NAME ?= {pkg}"):
            print("[patch_ksu_version] 找不到 KSU_PACKAGE_NAME 定义位置", file=sys.stderr)
            return 1

    open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"[patch_ksu_version] KSU_VERSION={version} KSU_PACKAGE_NAME={pkg} -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
