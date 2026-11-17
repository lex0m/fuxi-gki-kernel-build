# fuxi（小米 13）GKI 内核一键编译套件 —— SukiSU Nova + SUSFS + KPM

> 目标 ROM：HyperOS **OS2.0.215.0.VMCCNXM**（Android 15 / fuxi）
> 目标内核基线：ACK **android13-5.15-2024-11** / **5.15.167** / commit `bf0a81a7f319`
> 产出：`boot-fuxi-*.img`（header v4 / 无 ramdisk，可直接 `fastboot flash boot` 到当前槽）

## 0. 先说明：为什么"直接在本机编译"做不到

内核是 ARM64 Linux 构建，需要 **Linux + AOSP clang（r450784e）+ 30~50GB 磁盘 + 可访问 android.googlesource.com**。
你这台 Windows 机器：

- 没有 WSL 发行版、没有 git/python/编译工具链，C 盘只剩约 4GB；
- 本会话里 DSH 的终端工具也出现了 `Temp 目录 EPERM / ACL 锁` 错误，命令无法启动；
- 即使有 WSL，`repo sync` 还需要能稳定访问 Google（国内网络通常要代理）。

所以这里走 **GitHub Actions 云端构建**（推荐，免费、网络干净、30~60 分钟出包）：本目录就是"上传到 GitHub 就能跑"的完整套件。
你也可以把本目录拷到任意 Ubuntu 机器/云主机上 `bash scripts/build.sh`，脚本完全一样。

## 1. 目录结构

```
build-kit/
├─ .github/workflows/build-fuxi.yml   # GitHub Actions 工作流（手动触发、可选参数）
├─ scripts/
│  ├─ build.sh                        # 主构建脚本（同步源码→集成 Nova→SUSFS→编译→KPM→打包）
│  ├─ install-deps.sh                 # Ubuntu 依赖安装（repo/python3/编译工具链）
│  ├─ patch_ksu_version.py            # 把 KSU_VERSION / 包名固定进内核（必须与 APK 一致）
│  └─ apply_hooks.py                  # builtin 分支的 4 个手工 hook（仅 SUSFS 模式需要）
├─ configs/
│  ├─ fuxi-ksu.config                 # CONFIG_KSU=y / CONFIG_KPM=y
│  └─ fuxi-susfs.config               # CONFIG_KSU_SUSFS*（仅 SUSFS 模式）
└─ README.md
```

## 2. 方式 A：GitHub Actions（推荐，3 步）

1. **建仓库**：GitHub → New repository → 名字随意，如 `fuxi-kernel-build`。
   ⚠️ **建议设为 Public**：public 仓库的 Actions 标准 runner 是 4 核/16GB 内存且免费不限分钟；private 仓库是 2 核/7GB，5.15 的 FULL-LTO 链接可能 OOM。
2. **上传本目录内容**：把 `build-kit/` **里面的文件**（不是 build-kit 这一层）拖进仓库根目录并 Commit。
   注意保留 `.github/workflows/build-fuxi.yml` 的路径，否则 Actions 里看不到 workflow。
3. **触发构建**：仓库 → **Actions** → 左侧 **Build fuxi GKI kernel (SukiSU Nova / SUSFS / KPM)** →
   右侧 **Run workflow** → 填参数 → **Run workflow**。
   - 第一次会提示启用 workflow（若 Private 仓库）：确认启用即可。
   - 构建约 30–60 分钟（repo sync 占大头）。
4. **下载产物**：运行页底部 **Artifacts** → `fuxi-gki-kernel-main-kpm1`（zip）→ 解压得到
   `boot-fuxi-*.img` / `Image` / `Image.kpm` / `BUILD_INFO.txt` / `SHA256SUMS`。

### 管理器：SukiSU Nova v3.0.0（已确定）

内核构建参数固定用 `ksu_version=35000`、`ksu_pkg=com.sukisu.nova`（本套件默认值）。
APK：`SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk`
下载：https://github.com/SukiSU-Nova/SukiSU-Nova/releases/download/v3.0.0/SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk
SHA-256：`1202adb835a64d8b3df703da7884a2966f8728c131cffb29fb5f48d31d81ac85`
**安装顺序：先刷 boot → 开机确认内核正常 → 再 `adb install` 管理器**（管理器首次打开会自动装 ksud）。
完整刷机步骤见 [FLASH-SEQUENCE.md](FLASH-SEQUENCE.md)。

### 参数怎么填

| 输入 | 首次建议 | 说明 |
|---|---|---|
| `with_susfs` | **0** | 0 = main 分支（kprobe，稳定；SUSFS 之后用外挂 LKM）；1 = builtin + susfs4ksu 内置（实验性） |
| `inject_kpm` | **1** | 构建期把 KernelPatch 0.14.0 的 `kpimg` 注入 Image，KPM 才能用 |
| `ksu_version` | **35000**（用 Nova v3.0.0 APK） | 必须 = 管理器 APK 的 versionCode；用旧 Ultra APK 则填 41150 |
| `ksu_pkg` | **com.sukisu.nova** | 同上；旧 Ultra APK 填 com.sukisu.ultra |

### 产物验收（下载后本地检查）

```bash
# 1) 内核版本串（应为 5.15.167-android13-8 开头；不必逐字等于 stock）
strings Image | grep -m1 'Linux version'
# 2) boot header：v4 / page 4096 / ramdisk_size=0 / kernel 段约 47MB
#    方法一：用仓库里 mkbootimg 的 unpack_bootimg.py
python3 unpack_bootimg.py --boot_img boot-fuxi-xxxx.img --out boot_out && cat boot_out/bootimg_info.txt
# 3) 校验和
sha256sum -c SHA256SUMS
```

## 3. 刷机 / 回滚（重要：当前 BL 是锁的）

> 设备实测：`ro.boot.flash.locked=1`，**必须先解锁**；`fastboot flashing unlock` 会清空 /data。
> 刷内核只动 `boot` 分区，不动 `init_boot`/`vendor_boot`/`vbmeta`（解锁状态下 AVB 不强制）。

```bash
adb reboot bootloader
fastboot getvar current-slot          # 记下 a / b
# 先只刷当前槽，另一槽保留 stock 作为兜底
fastboot flash boot_a boot-fuxi-xxxx.img   # 若当前是 b 则 boot_b
fastboot reboot
```

开机后立即验证：
```bash
adb shell dmesg | grep -iE "version magic|disagrees about version|Unknown symbol|module_layout|CFI"
adb shell "ls /sys/module | wc -l; cat /proc/modules | wc -l"   # 应接近 stock 的 402
# 再试 WiFi / 相机 / 指纹 / 音频 / 触控
```

回滚（任何异常马上做）：
```bash
fastboot --slot=all flash boot "G:\MI13_Flash\rom\fuxi_images_OS2.0.215.0.VMCCNXM_15.0\images\boot.img"
fastboot reboot
# 整包救砖（保留数据）：ROM 目录里的 flash_all_except_storage.bat
```

**注意**：改过 boot 后官方 OTA 会覆盖回官方内核（root 丢失）；`init_boot` 不要动；
**永不重锁**（带修改重锁会 `system has been destroyed`）；anti=1 不要刷更低版本 ROM。

## 4. 方式 B：本地 Linux / 云主机

要求：Ubuntu 22.04/24.04，**>=50GB 空闲磁盘**，能访问 android.googlesource.com / github / gitlab。

```bash
cd build-kit
bash scripts/install-deps.sh
export PATH="$HOME/bin:$PATH"
KSU_VERSION=35000 KSU_PKG=com.sukisu.nova WITH_SUSFS=0 INJECT_KPM=1 \
  bash scripts/build.sh
# 产物在 build-kit/out/
```

## 5. 已知风险 / 未验证项（务必先小步验证）

1. **本套件未经真机验证**：fuxi + OS2.0.215 + 自编译 AOSP GKI 没有公开先例；脚本按一手资料写成，首次运行可能要按日志修 1~2 处小问题（repo manifest 名、susfs 补丁上下文）。
2. **SUSFS 内置模式（with_susfs=1）是实验性的**：需要 builtin 分支 + susfs4ksu 补丁 + 手工 hook 同时成功；建议第一版用 `with_susfs=0` 跑通，之后 SUSFS 用外挂 LKM（inforcqb/susfs4ksu-for-lkm 的 android13-5.15）验证整条链路，最后再试内置。
3. **KPM 注入产物未实测**：`kptools -p -s 123` 的 `-s` 校验参数按管理器同款命令；若启动异常，先用 `inject_kpm=0` 的版本，开机后在管理器里做 KPM 补丁。
4. **vendor 模块兼容**：已实测版本串首段不拦加载（5.15.78 的模块跑在 5.15.167 上），硬约束是 KMI + 导出符号 CRC + `module_layout`；如出现 `disagrees about version of symbol module_layout`，优先怀疑 KPM 注入改了 `struct module`，改用 `inject_kpm=0` 验证。
5. **磁盘**：GitHub 托管 runner 默认只有 ~14GB 空闲，工作流第一步做了激进清理（删 dotnet/android/ghc/toolcache）；若仍失败，换 self-hosted runner 或本地 Linux。
6. **管理器匹配**：内核里的 KSU_VERSION/包名必须与 APK 一致，否则管理器提示"需要更新内核"。用 Nova v3.0.0 APK（`SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk`）最稳。

## 6. 兜底方案（不自编内核）

如果编译长时间不顺，可先用官方 LKM 路线拿到 root，再回头编：
- Nova v3.0.0 APK + release 的 `lkm-aarch64-android13-5.15_kernelsu.ko` 给 `init_boot` 打补丁 → fastboot 刷 `init_boot` → root；
- SUSFS 用 `susfs_guard_lkm-android13-5.15.ko`（inforcqb/susfs4ksu-for-lkm）；
- KPM 用管理器"KPM 补丁"给 boot 内核注入 KernelPatch（需已有 root）。
> 这条路线全程不需要 Linux 编译，适合先验证"解锁→root→SUSFS→KPM"整条链路。

## 7. 参考

- 调研汇总：[../SukiSU-Nova-fuxi-GKI内核-注意事项.md](../SukiSU-Nova-fuxi-GKI内核-注意事项.md)
- 4 份专题：[../research/](../research/)
- SukiSU Nova：https://github.com/SukiSU-Nova/SukiSU-Nova ｜ https://sukisu.org
- GKI 发布 build：https://source.android.google.cn/docs/core/architecture/kernel/gki-android13-5_15-release-builds
- KernelPatch 0.14.0（kptools/kpimg）：https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch/releases/tag/0.14.0
- SUSFS 内核补丁：https://gitlab.com/simonpunk/susfs4ksu
