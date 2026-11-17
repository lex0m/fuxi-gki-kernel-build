#!/usr/bin/env python3
"""给 Linux 5.15 内核源码注入 SukiSU builtin 分支需要的手工 hook。

SukiSU Nova 的 `builtin` 分支不使用 kprobe，需要在内核源码里手工插 4 个 hook
（execve / faccessat / newfstatat / reboot）。本脚本用“关键字符串定位”而不是
上下文 patch，能在 5.15.167 上稳定工作；找不到目标时直接报错退出，方便发现内核
结构变化。

用法：apply_hooks.py <内核源码根目录，即包含 fs/ kernel/ 的目录>
说明：主分支（kprobe 模式）不需要跑本脚本。
"""
import re
import sys

MARK = "ksu_handle_execveat"  # 任意一处已存在则认为已打过


def read(p):
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)


def insert_before(text, anchor, block, path):
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到锚点 {anchor!r}")
    return text[:idx] + block + text[idx:]


def patch_exec(root):
    path = f"{root}/fs/exec.c"
    src = read(path)
    if "ksu_handle_execveat" in src:
        print(f"[hooks] {path}: 已存在，跳过")
        return
    func = "static int do_execveat_common("
    fidx = src.find(func)
    if fidx < 0:
        func = "static int __do_execve_file("
        fidx = src.find(func)
    if fidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 do_execveat_common，请人工处理")
    anchor = "if (IS_ERR(filename))"
    aidx = src.find(anchor, fidx)
    if aidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 IS_ERR(filename) 锚点")
    # 缩进对齐到锚点所在行
    line_start = src.rfind("\n", 0, aidx) + 1
    indent = src[line_start:aidx]
    block = (
        f"{indent}#ifdef CONFIG_KSU\n"
        f"{indent}\textern int ksu_handle_execveat(int *, struct filename **, void *, void *, int *);\n"
        f"{indent}\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        f"{indent}#endif\n"
    )
    src = src[:line_start] + block + src[line_start:]
    write(path, src)
    print(f"[hooks] {path}: execve hook 已插入")


def patch_faccessat(root):
    path = f"{root}/fs/open.c"
    src = read(path)
    if "ksu_handle_faccessat" in src:
        print(f"[hooks] {path}: 已存在，跳过")
        return
    sig = "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)"
    sidx = src.find(sig)
    if sidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 faccessat 定义")
    bidx = src.find("{", sidx)
    if bidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 faccessat 函数体")
    nl = src.find("\n", bidx)
    block = (
        "\n#ifdef CONFIG_KSU\n"
        "\textern int ksu_handle_faccessat(int *, const char __user **, int *, int *);\n"
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
        "#endif\n"
    )
    src = src[: nl + 1] + block + src[nl + 1:]
    write(path, src)
    print(f"[hooks] {path}: faccessat hook 已插入")


def patch_newfstatat(root):
    path = f"{root}/fs/stat.c"
    src = read(path)
    if "ksu_handle_stat" in src:
        print(f"[hooks] {path}: 已存在，跳过")
        return
    sig = "SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,"
    sidx = src.find(sig)
    if sidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 newfstatat 定义")
    anchor = "error = vfs_fstatat(dfd, filename, &stat, flag);"
    aidx = src.find(anchor, sidx)
    if aidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 vfs_fstatat 调用")
    line_start = src.rfind("\n", 0, aidx) + 1
    indent = src[line_start:aidx]
    block = (
        f"{indent}#ifdef CONFIG_KSU\n"
        f"{indent}\textern int ksu_handle_stat(int *, const char __user **, int *);\n"
        f"{indent}\tksu_handle_stat(&dfd, &filename, &flag);\n"
        f"{indent}#endif\n\n"
    )
    src = src[:line_start] + block + src[line_start:]
    write(path, src)
    print(f"[hooks] {path}: newfstatat hook 已插入")


def patch_reboot(root):
    path = f"{root}/kernel/reboot.c"
    src = read(path)
    if "ksu_handle_sys_reboot" in src:
        print(f"[hooks] {path}: 已存在，跳过")
        return
    sig = "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,"
    sidx = src.find(sig)
    if sidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 reboot 定义")
    anchor = "/* We only trust the superuser with rebooting the system. */"
    aidx = src.find(anchor, sidx)
    if aidx < 0:
        raise SystemExit(f"[hooks] {path}: 找不到 reboot 注释锚点")
    line_start = src.rfind("\n", 0, aidx) + 1
    indent = src[line_start:aidx]
    block = (
        f"{indent}#ifdef CONFIG_KSU\n"
        f"{indent}\textern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\n"
        f"{indent}\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
        f"{indent}#endif\n\n"
    )
    src = src[:line_start] + block + src[line_start:]
    write(path, src)
    print(f"[hooks] {path}: reboot hook 已插入")


def main():
    if len(sys.argv) != 2:
        print("usage: apply_hooks.py <kernel_source_root>", file=sys.stderr)
        return 2
    root = sys.argv[1].rstrip("/")
    patch_exec(root)
    patch_faccessat(root)
    patch_newfstatat(root)
    patch_reboot(root)
    print("[hooks] 完成：4 个 hook 处理完毕（builtin 分支）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
