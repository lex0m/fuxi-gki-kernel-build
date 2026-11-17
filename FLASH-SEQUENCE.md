# fuxi 刷机顺序（内核模式 + SukiSU Nova v3.0.0 管理器）

> 目标：把 `boot-fuxi-*.img` 刷进 fuxi，开机后用 **SukiSU Nova v3.0.0（versionCode 35000）** 管理器接管。
> 前提：bootloader 已解锁（当前实测是锁定状态，解锁会清数据）；已拿到构建产物 `boot-fuxi-*.img`。

## 0. 管理器 APK（先下载好，刷完内核再装）

- 文件名：`SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk`
- 下载：https://github.com/SukiSU-Nova/SukiSU-Nova/releases/download/v3.0.0/SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk
- SHA-256：`1202adb835a64d8b3df703da7884a2966f8728c131cffb29fb5f48d31d81ac85`
- 注意：内核构建参数必须用 `ksu_version=35000`、`ksu_pkg=com.sukisu.nova`（本套件默认值），否则管理器会提示"需要更新内核"。
- 旧的 `SukiSU_v4.3.0-r2_41150-release.apk` 也能被新内核认（同一签名证书），但版本号对不上，不推荐混用。

## 1. 刷入前（电脑上）

```bash
# 1) 手机开机、USB 调试、adb 能识别
adb devices
# 2) 备份现有 boot（解锁后、刷入前，用当前 ROM 的 boot.img 即可作为回滚包）
#    G:\MI13_Flash\rom\fuxi_images_OS2.0.215.0.VMCCNXM_15.0\images\boot.img
# 3) 记下当前槽位
adb reboot bootloader
fastboot getvar current-slot
fastboot getvar unlocked          # 必须是 yes / 1；locked 则先解锁
```

## 2. 只刷当前槽（先验证，另一槽保留原厂兜底）

```bash
# 当前槽是 a 就刷 boot_a；是 b 就刷 boot_b
fastboot flash boot_a boot-fuxi-xxxx.img
fastboot reboot
```

首次开机 2–5 分钟，别断电。

## 3. 开机后验证（先别装任何东西）

```bash
adb shell dmesg | grep -iE "version magic|disagrees about version|Unknown symbol|module_version|module_layout|CFI"
adb shell "ls /sys/module | wc -l; cat /proc/modules | wc -l"
adb shell "getprop ro.boot.verifiedbootstate"      # 解锁状态通常 orange
# 手动验证：WiFi、相机（前后）、指纹、声音、触控、UFS 读写
```

稳定 → 刷另一槽，让它也一致：

```bash
adb reboot bootloader
fastboot --slot=all flash boot boot-fuxi-xxxx.img
fastboot reboot
```

## 4. 安装 Nova v3.0.0 管理器

```bash
adb install -r SukiSU_Nova_v3.0.0_35000-arm64-v8a-release.apk
# 打开管理器：
#  - 首页应显示 "Built-in"（内核模式已识别）
#  - 若显示预览/未检测到内核：确认 boot 刷的是自定义内核、KSU_VERSION=35000
#  - 首次打开会 request root/安装 ksud，允许即可
adb shell su -c id        # 应返回 uid=0
```

## 5. KPM / SUSFS（按需，最后做）

- **KPM**：若构建时 `inject_kpm=1`，管理器 KPM 页应能加载 `.kpm`（先拿 `demo-hello.kpm` 试）；
  若构建时是 `inject_kpm=0`：管理器 → 刷入/修补内核 → 对当前 boot 做 **KPM 补丁**（会自动备份原 boot）→ 重启。
- **SUSFS**：
  - 构建时 `with_susfs=0`（main 分支）：用外挂 `susfs_guard_lkm-android13-5.15.ko`（inforcqb/susfs4ksu-for-lkm），管理器 Extensions 里确认 `susfs` 有版本号；
  - 构建时 `with_susfs=1`（builtin 内置）：管理器 SUSFS 页应直接可用（实验路径，先小范围测试）。
- 配置隐藏项后，再测银行/检测类 App。

## 6. 回滚（任何一步不对，立刻执行）

```bash
# 方法 1：刷回原厂 boot（最快）
adb reboot bootloader
fastboot --slot=all flash boot "G:\MI13_Flash\rom\fuxi_images_OS2.0.215.0.VMCCNXM_15.0\images\boot.img"
fastboot reboot

# 方法 2：整包回刷（保留数据）
#   双击 ROM 目录里的 flash_all_except_storage.bat（手机关机，音量下+电源进 fastboot）
```

## 7. 红线

- **不要刷 init_boot / vendor_boot / dtbo**（内核在 boot 分区，ramdisk 在 init_boot，不要动）。
- **不要动 vbmeta**（解锁状态 AVB 不强制；改 vbmeta 后不能重锁）。
- **永不重锁**：带任何修改重锁 = "system has been destroyed"/可能变砖；要重锁先整包回 stock。
- 改过 boot 后官方 OTA 会覆盖内核；升级前留好回滚包。
- 保留：`boot.img`（原厂）、`build.log`、`SHA256SUMS`、本次 `boot-fuxi-*.img`。
