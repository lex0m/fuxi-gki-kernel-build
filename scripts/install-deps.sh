#!/usr/bin/env bash
# 安装 AOSP GKI 构建依赖（Ubuntu 22.04/24.04、GitHub Actions 均可）
# 用法：bash scripts/install-deps.sh
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
  git curl ca-certificates python3 bc bison build-essential flex \
  libelf-dev libssl-dev libncurses-dev rsync unzip zip lz4 ccache \
  xz-utils cpio kmod patch

mkdir -p "$HOME/bin"
if [ ! -x "$HOME/bin/repo" ]; then
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod +x "$HOME/bin/repo"
fi
export PATH="$HOME/bin:$PATH"

if ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "fuxi-kernel-build"
fi
if ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "fuxi-kernel-build@localhost"
fi

echo "[install-deps] OK. repo: $($HOME/bin/repo --version 2>/dev/null || echo '?')"
