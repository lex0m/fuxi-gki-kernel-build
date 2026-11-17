#!/usr/bin/env bash
# =============================================================================
# fuxi (Xiaomi 13) GKI 5.15.167 内核构建脚本 —— SukiSU Nova + (可选)SUSFS + (可选)KPM
#
# 用法（在 build-kit 目录下）：
#   KSU_VERSION=35000 KSU_PKG=com.sukisu.nova WITH_SUSFS=0 INJECT_KPM=1 \
#     bash scripts/build.sh
#
# 可覆盖环境变量：
#   WORK         工作目录（默认 ./work，需 >= 40GB 空闲；AOSP 源码会同步到这里）
#   OUT          产物目录（默认 ./out）
#   KSU_VERSION  写进内核的 KSU 版本号，必须与所用管理器 APK 的 versionCode 一致
#   KSU_PKG      管理器包名（nova=com.sukisu.nova；旧 Ultra APK=com.sukisu.ultra）
#   WITH_SUSFS   1 = builtin 分支 + susfs4ksu 补丁（实验性）；0 = main 分支（默认，稳定）
#   INJECT_KPM   1 = 下载 KernelPatch 0.14.0 的 kptools/kpimg 把 KPM 宿主注入 Image（默认 1）
#   SKIP_SYNC    1 = 跳过 repo init/sync（复用已有 work/）
#   MANIFEST_REF 可强制指定 kernel/manifest 的 ref（默认自动探测 ...2024-11 分支）
#
# 产物（$OUT/）：
#   Image / Image.kpm（已注入 KernelPatch 时） / boot-fuxi-*.img / build.log
#   .config / System.map / Module.symvers / BUILD_INFO.txt / SHA256SUMS
# =============================================================================
set -euo pipefail

log() { printf '\n\033[1;32m===== %s =====\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 输入参数 ----------------------------------------------------------------
: "${KSU_VERSION:=35000}"
: "${KSU_PKG:=com.sukisu.nova}"
: "${WITH_SUSFS:=0}"
: "${INJECT_KPM:=1}"
: "${SKIP_SYNC:=0}"
: "${MANIFEST_REF:=}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${WORK:=$BASE_DIR/work}"
: "${OUT:=$BASE_DIR/out}"

KERNEL_MANIFEST="https://android.googlesource.com/kernel/manifest"
KSU_REPO="https://github.com/SukiSU-Nova/SukiSU-Nova"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_MIRROR="https://github.com/jiekaai/fuxi-susfs"
SUSFS_BRANCH="gki-android13-5.15"
STOCK_COMMIT="bf0a81a7f319a3fa67af9729fe36783ffb1f5e7d"
KP_VER="0.14.0"
KP_BASE="https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch/releases/download/${KP_VER}"

mkdir -p "$OUT"
log "fuxi GKI 构建开始：KSU_VERSION=$KSU_VERSION KSU_PKG=$KSU_PKG WITH_SUSFS=$WITH_SUSFS INJECT_KPM=$INJECT_KPM"
log "WORK=$WORK OUT=$OUT"

# ---- 1. repo sync（AOSP ACK android13-5.15-2024-11） --------------------------
if [ "$SKIP_SYNC" != "1" ]; then
  if [ ! -d "$WORK/.repo" ]; then
    log "初始化 kernel/manifest（自动探测 2024-11 ref）"
    mkdir -p "$WORK"
    REF="$MANIFEST_REF"
    if [ -z "$REF" ]; then
      ALL_REFS="$(git ls-remote "$KERNEL_MANIFEST" | awk '{print $2}')"
      REF="$(printf '%s\n' "$ALL_REFS" | sed -n 's#^refs/heads/##p' |
             grep -E 'android13-5\.15' | grep -E '2024-11' | head -n1 || true)"
      if [ -z "$REF" ]; then
        REF="$(printf '%s\n' "$ALL_REFS" | sed -n 's#^refs/tags/##p' |
               grep -E 'android13-5\.15' | grep -E '2024-11' | head -n1 || true)"
      fi
    fi
    [ -n "$REF" ] || { printf '%s\n' "$ALL_REFS" | grep -E 'android13-5\.15' | tail -n 20;
                       die "找不到 android13-5.15 的 2024-11 manifest ref，请手动传 MANIFEST_REF=..."; }
    log "使用 manifest ref: $REF"
    ( cd "$WORK"
      repo init -u "$KERNEL_MANIFEST" -b "$REF" --no-repo-verify )

    repo_sync_once() {
      ( cd "$WORK"
        repo sync -c -j"$(nproc)" --no-clone-bundle --retry-fetches=3 )
    }
    if ! repo_sync_once; then
      log "首次 repo sync 失败，探测可用 refs 并尝试回退（deprecated 分支 / tag / 移动分支）"
      COMMON_URL="https://android.googlesource.com/kernel/common"
      git ls-remote "$COMMON_URL" > "$WORK/refs-common.txt" 2>/dev/null || true
      log "kernel/common 里含 2024-11 的 refs（前 40 行）:"
      grep -E '2024-11' "$WORK/refs-common.txt" | head -n 40 || true
      MANI="$WORK/.repo/manifests"
      DEP="deprecated/android13-5.15-2024-11"
      if grep -q "refs/heads/$DEP" "$WORK/refs-common.txt"; then
        log "回退方案 1：manifest 里把 android13-5.15-2024-11 改成 $DEP"
        find "$MANI" -name '*.xml' -exec sed -i "s#android13-5\.15-2024-11#$DEP#g" {} +
      else
        TAG="$(grep -oE 'refs/tags/android13-5\.15-2024-11[^[:space:]]*' "$WORK/refs-common.txt" | head -n1 | sed 's#^refs/tags/##' || true)"
        if [ -n "$TAG" ]; then
          log "回退方案 2：manifest 里把 revision 改成 tag: $TAG"
          find "$MANI" -name '*.xml' -exec sed -i "s#revision=\"android13-5\.15-2024-11\"#revision=\"$TAG\"#g" {} +
        else
          log "回退方案 3：退回 manifest 分支 common-android13-5.15（移动 LTS 分支），随后仍 checkout 固定 commit"
          ( cd "$WORK"; repo init -u "$KERNEL_MANIFEST" -b common-android13-5.15 --no-repo-verify )
        fi
      fi
      repo_sync_once || die "repo sync 仍然失败（已尝试 deprecated/tag/移动分支回退）"
    fi
  else
    log "复用已有 repo：$WORK"
  fi
else
  log "SKIP_SYNC=1，跳过源码同步"
fi

[ -d "$WORK/common" ] || die "找不到 $WORK/common，源码同步未完成"
KERNEL_DIR="$WORK/common"

log "checkout stock 对应 commit：$STOCK_COMMIT"
git -C "$KERNEL_DIR" checkout -q "$STOCK_COMMIT" ||
  die "checkout $STOCK_COMMIT 失败（repo 是否完整同步？）"
log "内核源码 HEAD = $(git -C "$KERNEL_DIR" rev-parse --short HEAD) $(git -C "$KERNEL_DIR" log -1 --format=%s)"

# ---- 2. 集成 SukiSU Nova ------------------------------------------------------
KSU_BRANCH="main"
[ "$WITH_SUSFS" = "1" ] && KSU_BRANCH="builtin"
log "克隆 SukiSU Nova（分支 $KSU_BRANCH）"
rm -rf "$WORK/ksu-src"
git clone --depth 1 --branch "$KSU_BRANCH" "$KSU_REPO" "$WORK/ksu-src"

log "把 kernel/ 复制进 drivers/kernelsu 并挂接 Kbuild/Kconfig"
rm -rf "$KERNEL_DIR/drivers/kernelsu"
cp -a "$WORK/ksu-src/kernel" "$KERNEL_DIR/drivers/kernelsu"

# 上游 kernel/include/uapi 是指向仓库根 uapi/ 的相对符号链接（../../uapi）。
# 把 kernel/ 复制到内核树后该链接指向 <kernel>/drivers/uapi（不存在），
# 于是 policy/allowlist.h 的 #include "uapi/app_profile.h" 找不到头文件。
# 这里把真实 uapi 目录替换到 kernelsu/include/uapi，保持 -I.../kernelsu/include 可用。
log "修复 kernelsu 的 uapi 头文件目录（上游为跨目录相对符号链接）"
rm -rf "$KERNEL_DIR/drivers/kernelsu/include/uapi"
mkdir -p "$KERNEL_DIR/drivers/kernelsu/include"
cp -a "$WORK/ksu-src/uapi" "$KERNEL_DIR/drivers/kernelsu/include/uapi"
for h in app_profile.h ksu.h supercall.h; do
  [ -f "$KERNEL_DIR/drivers/kernelsu/include/uapi/$h" ] ||
    die "uapi 目录复制失败：缺少 include/uapi/$h"
done
log "  uapi 头文件数：$(ls -1 "$KERNEL_DIR/drivers/kernelsu/include/uapi" | wc -l)"
grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" ||
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" ||
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"

log "锁定 KSU_VERSION=$KSU_VERSION / KSU_PACKAGE_NAME=$KSU_PKG"
python3 "$BASE_DIR/scripts/patch_ksu_version.py" \
  "$KERNEL_DIR/drivers/kernelsu/Kbuild" "$KSU_VERSION" "$KSU_PKG"

# ---- 3. 可选：SUSFS（builtin + susfs4ksu 补丁） ------------------------------
if [ "$WITH_SUSFS" = "1" ]; then
  log "SUSFS：克隆 susfs4ksu（$SUSFS_BRANCH）"
  rm -rf "$WORK/susfs4ksu"
  git clone --depth 1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" "$WORK/susfs4ksu" ||
    { log "gitlab 失败，尝试镜像 $SUSFS_MIRROR"; rm -rf "$WORK/susfs4ksu";
      git clone --depth 1 --branch "$SUSFS_BRANCH" "$SUSFS_MIRROR" "$WORK/susfs4ksu"; } ||
    die "susfs4ksu 克隆失败（gitlab 与镜像都不通）"

  PATCH_FILE="$WORK/susfs4ksu/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
  [ -f "$PATCH_FILE" ] || die "找不到 SUSFS 补丁：$PATCH_FILE（仓库结构可能变化）"

  log "复制 SUSFS 新增文件并应用内核补丁"
  cp -a "$WORK/susfs4ksu/kernel_patches/fs/." "$KERNEL_DIR/fs/"
  cp -a "$WORK/susfs4ksu/kernel_patches/include/linux/." "$KERNEL_DIR/include/linux/"
  patch -p1 -d "$KERNEL_DIR" < "$PATCH_FILE" ||
    die "SUSFS 补丁应用失败（多半是 5.15.167 源码与补丁上下文不符，需要手工 rebase）"

  log "给 builtin 分支打 SukiSU 手工 hook（execve/faccessat/newfstatat/reboot）"
  python3 "$BASE_DIR/scripts/apply_hooks.py" "$KERNEL_DIR"

  log "追加 SUSFS 内核配置"
  cat "$BASE_DIR/configs/fuxi-susfs.config" >> "$KERNEL_DIR/arch/arm64/configs/gki_defconfig"
fi

# ---- 4. 追加 KSU/KPM 内核配置 -------------------------------------------------
log "追加 KSU/KPM 内核配置到 gki_defconfig"
cat "$BASE_DIR/configs/fuxi-ksu.config" >> "$KERNEL_DIR/arch/arm64/configs/gki_defconfig"

# ---- 5. 编译（AOSP GKI 构建脚本，自动用 manifest 固定的 clang/LTO/CFI） -------
if [ -x "$WORK/build/build.sh" ]; then
  BUILD_SH="$WORK/build/build.sh"
elif [ -x "$WORK/common/build/build.sh" ]; then
  BUILD_SH="$WORK/common/build/build.sh"
else
  die "找不到 build/build.sh，请检查 repo 同步结果"
fi
log "跳过 AOSP 的 defconfig 一致性检查（我们追加了 CONFIG_KSU/CONFIG_KPM，必然与 gki_defconfig 不一致）"
PATCHED=0
while IFS= read -r f; do
  case "$f" in
    *build.config*)
      sed -i 's/check_defconfig/true/g' "$f"
      log "  已处理: $f (POST_DEFCONFIG_CMDS)"
      PATCHED=$((PATCHED+1))
      ;;
  esac
done < <(grep -rl 'check_defconfig' "$WORK/common" "$WORK/build" 2>/dev/null || true)
log "  处理文件数: $PATCHED"

log "开始编译：BUILD_CONFIG=common/build.config.gki.aarch64 $BUILD_SH"
( cd "$WORK"
  BUILD_CONFIG=common/build.config.gki.aarch64 "$BUILD_SH" 2>&1 | tee "$OUT/build.log" )

IMAGE="$(find "$WORK/out" -path '*/dist/Image' -type f | head -n1 || true)"
[ -n "$IMAGE" ] || { log "out 目录结构："; find "$WORK/out" -maxdepth 4 -name 'Image*' -o -maxdepth 4 -name 'dist' | head -n 30;
                     die "编译结束但找不到 dist/Image，请查看 $OUT/build.log"; }
cp -f "$IMAGE" "$OUT/Image"
log "内核编译成功：$IMAGE"
log "内核版本串：$(strings "$OUT/Image" | grep -m1 'Linux version' || true)"

# 附带产物（有就拷）
for f in .config System.map Module.symvers; do
  p="$(find "$WORK/out" -name "$f" | head -n1 || true)"
  [ -n "$p" ] && cp -f "$p" "$OUT/$f" || true
done

# ---- 6. 可选：KPM 宿主注入（kptools + kpimg，KernelPatch 0.14.0） -------------
BOOT_KERNEL="$OUT/Image"
if [ "$INJECT_KPM" = "1" ]; then
  log "KPM：下载 kptools-linux / kpimg（KernelPatch $KP_VER）"
  curl -fL --retry 3 -o "$OUT/kptools-linux" "$KP_BASE/kptools-linux"
  curl -fL --retry 3 -o "$OUT/kpimg"        "$KP_BASE/kpimg"
  chmod +x "$OUT/kptools-linux"
  log "KPM：注入 KernelPatch 宿主"
  "$OUT/kptools-linux" -p -s 123 -i "$OUT/Image" -k "$OUT/kpimg" -o "$OUT/Image.kpm" ||
    die "kptools 注入失败（见上一条输出）"
  [ -s "$OUT/Image.kpm" ] || die "Image.kpm 为空"
  BOOT_KERNEL="$OUT/Image.kpm"
  log "KPM 注入完成：$OUT/Image.kpm"
else
  log "INJECT_KPM=0，跳过 KernelPatch 注入（之后仍可在管理器里做 KPM 补丁）"
fi

# ---- 7. 打包 boot.img（fuxi: header v4 / 4096 / 无 ramdisk / 无 cmdline） ------
log "打包 boot.img"
if [ ! -d "$WORK/mkbootimg-src/.git" ]; then
  git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$WORK/mkbootimg-src"
fi
BOOT_IMG="$OUT/boot-fuxi-$(date +%Y%m%d-%H%M).img"
python3 "$WORK/mkbootimg-src/mkbootimg.py" \
  --header_version 4 \
  --kernel "$BOOT_KERNEL" \
  --output "$BOOT_IMG"
[ -s "$BOOT_IMG" ] || die "boot.img 打包失败"
log "boot.img：$BOOT_IMG ($(stat -c%s "$BOOT_IMG") bytes)"

# 自检 boot header
python3 "$WORK/mkbootimg-src/unpack_bootimg.py" --boot_img "$BOOT_IMG" --out "$OUT/unpacked-check" >/dev/null 2>&1 || true
if [ -f "$OUT/unpacked-check/bootimg_info.txt" ]; then
  cp -f "$OUT/unpacked-check/bootimg_info.txt" "$OUT/bootimg_info.txt"
  log "boot header 自检："; sed -n '1,20p' "$OUT/bootimg_info.txt" || true
fi

# ---- 8. 构建信息与校验和 ------------------------------------------------------
{
  echo "build_time=$(date -u +%FT%TZ)"
  echo "device=fuxi (Xiaomi 13)"
  echo "rom=OS2.0.215.0.VMCCNXM"
  echo "kernel_base=android13-5.15-2024-11 / 5.15.167 / commit $STOCK_COMMIT"
  echo "sukisu_branch=$KSU_BRANCH"
  echo "ksu_version=$KSU_VERSION"
  echo "ksu_pkg=$KSU_PKG"
  echo "with_susfs=$WITH_SUSFS"
  echo "inject_kpm=$INJECT_KPM"
  echo "kernel_release=$(strings "$BOOT_KERNEL" | grep -m1 'Linux version' || true)"
  echo "boot_img=$(basename "$BOOT_IMG") boot_img_size=$(stat -c%s "$BOOT_IMG")"
} > "$OUT/BUILD_INFO.txt"

( cd "$OUT" && sha256sum Image boot-fuxi-*.img 2>/dev/null > SHA256SUMS || true
  [ -f Image.kpm ] && sha256sum Image.kpm >> SHA256SUMS
  [ -f bootimg_info.txt ] && true )

log "全部完成。产物在：$OUT"
ls -lh "$OUT" | sed -n '1,40p'
cat "$OUT/BUILD_INFO.txt"
