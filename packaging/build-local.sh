#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 本地跑一遍 GitHub Actions 做的事（需要本机有 docker）。
#
#   bash packaging/build-local.sh              # 版本号自动从 src/core/nginx.h 读
#   bash packaging/build-local.sh 1.29.0       # 指定版本号
#
# Windows 上用 Git Bash 跑时，脚本会自动关掉路径转换。
# ---------------------------------------------------------------------------
set -euo pipefail

# Git Bash / MSYS 会把 "-v /work" 改写成 Windows 路径，必须关掉
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VER="${1:-}"
if [ -z "$VER" ]; then
    VER="$(sed -n 's/^#define[[:space:]]\+NGINX_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' src/core/nginx.h | head -n1)"
fi
if [ -z "$VER" ]; then
    echo "无法从 src/core/nginx.h 识别 NGINX_VERSION，请手动传入版本号" >&2
    exit 1
fi

mkdir -p dist out
rm -f out/*.rpm out/*.deb 2>/dev/null || true

echo "==> nginx ${VER}"
git archive --format=tar.gz --prefix="nginx-${VER}/" -o "dist/nginx-${VER}.tar.gz" HEAD

build() {
    local image="$1" kind="$2"
    echo
    echo "==> ${kind} @ ${image}"
    docker pull -q "$image"
    docker run --rm \
        --volume "${REPO_ROOT}:/work" \
        --workdir /work \
        --env NGINX_VERSION="$VER" \
        --env DIST_DIR=/work/dist \
        --env OUT_DIR=/work/out \
        "$image" \
        bash "/work/packaging/build-${kind}.sh"
}

build docker.io/library/centos:7     rpm
build docker.io/library/ubuntu:20.04 deb
build docker.io/library/ubuntu:22.04 deb

# Linux 主机上容器以 root 身份写出来的文件需要改回来
sudo chown -R "$(id -u):$(id -g)" dist out 2>/dev/null || true

echo
echo "==> 产物："
ls -l out
