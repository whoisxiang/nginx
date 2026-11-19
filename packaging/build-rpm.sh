#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 在 CentOS 7 容器里把源码 tarball 打成 RPM。
# 由 .github/workflows/build-packages.yml 调用，也可以在本地 docker 里跑。
#
# 必需环境变量：
#   NGINX_VERSION   例如 1.29.0
# 可选环境变量：
#   DIST_DIR        tarball 所在目录，默认 /work/dist
#   OUT_DIR         产物输出目录，默认 /work/out
#   PACKAGING_DIR   packaging/ 目录，默认 /work/packaging
#   NGINX_USER      运行用户，默认 nginx
#   WORK_DIR        构建临时目录，默认 /work/build/rpm
# ---------------------------------------------------------------------------
set -euo pipefail

: "${NGINX_VERSION:?NGINX_VERSION is required}"
DIST_DIR="${DIST_DIR:-/work/dist}"
OUT_DIR="${OUT_DIR:-/work/out}"
PACKAGING_DIR="${PACKAGING_DIR:-/work/packaging}"
NGINX_USER="${NGINX_USER:-nginx}"
WORK_DIR="${WORK_DIR:-/work/build/rpm}"

SRC_TARBALL="${DIST_DIR}/nginx-${NGINX_VERSION}.tar.gz"
TOP_DIR="${WORK_DIR}/rpmbuild"

echo "==> nginx ${NGINX_VERSION} / RPM / CentOS $(rpm -q --qf '%{VERSION}' centos-release 2>/dev/null || echo 7)"

if [ ! -f "$SRC_TARBALL" ]; then
    echo "missing source tarball: ${SRC_TARBALL}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. CentOS 7 已于 2024-06-30 EOL，官方镜像里的 mirror.centos.org 已经下线，
#    必须把源切到 vault.centos.org，否则 yum install 直接失败。
# ---------------------------------------------------------------------------
if [ -f /etc/yum.repos.d/CentOS-Base.repo ]; then
    sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
           -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
           /etc/yum.repos.d/CentOS-Base.repo
fi

if ! grep -q '^baseurl=http://vault.centos.org' /etc/yum.repos.d/CentOS-Base.repo 2>/dev/null; then
    echo "==> CentOS-Base.repo 不可用，改用只指向 vault 的源"
    # 把原有 repo 文件改成 .disabled（yum 只认 *.repo），避免残留的 mirrorlist 拖死 yum
    for f in /etc/yum.repos.d/CentOS-*.repo; do
        [ -f "$f" ] || continue
        mv "$f" "${f}.disabled"
    done
    cat > /etc/yum.repos.d/CentOS-Vault-Base.repo <<'EOF'
[base]
name=CentOS-7 - Base - vault.centos.org
baseurl=http://vault.centos.org/centos/7/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates - vault.centos.org
baseurl=http://vault.centos.org/centos/7/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras - vault.centos.org
baseurl=http://vault.centos.org/centos/7/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
fi

yum -y clean all
yum -y install gcc make rpm-build redhat-rpm-config \
               pcre-devel zlib-devel openssl-devel libaio-devel perl

# ---------------------------------------------------------------------------
# 2. %files 里 %attr(...,nginx,nginx) 需要该用户在打包时就存在
# ---------------------------------------------------------------------------
getent group "$NGINX_USER" >/dev/null || groupadd -r "$NGINX_USER"
getent passwd "$NGINX_USER" >/dev/null || \
    useradd -r -g "$NGINX_USER" -d /var/lib/nginx -s /sbin/nologin -M "$NGINX_USER"

# ---------------------------------------------------------------------------
# 3. 准备 rpmbuild 目录树
# ---------------------------------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "${TOP_DIR}/BUILD" "${TOP_DIR}/BUILDROOT" "${TOP_DIR}/RPMS" \
         "${TOP_DIR}/SOURCES" "${TOP_DIR}/SPECS" "${TOP_DIR}/SRPMS"

cp "$SRC_TARBALL"                    "${TOP_DIR}/SOURCES/"
cp "${PACKAGING_DIR}/common/nginx.service"   "${TOP_DIR}/SOURCES/"
cp "${PACKAGING_DIR}/common/nginx.logrotate" "${TOP_DIR}/SOURCES/"
cp "${PACKAGING_DIR}/rpm/nginx.spec.in"      "${TOP_DIR}/SPECS/nginx.spec"

sed -i -e "s|@VERSION@|${NGINX_VERSION}|g" \
       -e "s|@NGINX_USER@|${NGINX_USER}|g" \
       "${TOP_DIR}/SPECS/nginx.spec"

# 4. configure 参数交给 spec 里的 mapfile 读，避免空格被二次切分
# shellcheck source=/dev/null
. "${PACKAGING_DIR}/configure-args.sh"
printf '%s\n' "${nginx_configure_args[@]}" > "${TOP_DIR}/SOURCES/configure.args"

echo "==> configure options:"
cat "${TOP_DIR}/SOURCES/configure.args"

echo "==> rpmbuild"
rpmbuild -bb \
    --define "_topdir ${TOP_DIR}" \
    --define "_tmppath /tmp" \
    --define "dist .el7" \
    --define "_unitdir /usr/lib/systemd/system" \
    "${TOP_DIR}/SPECS/nginx.spec"

# ---------------------------------------------------------------------------
# 5. 冒烟测试：在同一个容器里真的装上，验证 %files 完整、scriptlet 不炸、配置合法
#    （容器里没有 systemd，scriptlet 里的 systemctl 会被跳过，正好能测无 systemd 场景）
# ---------------------------------------------------------------------------
RPM_FILE="$(find "${TOP_DIR}/RPMS" -name '*.rpm' | head -n1)"
echo "==> smoke test: installing ${RPM_FILE}"
if ! yum -y install --nogpgcheck "$RPM_FILE" > /tmp/nginx-rpm-install.log 2>&1; then
    echo "yum install of the built package failed:" >&2
    cat /tmp/nginx-rpm-install.log >&2
    exit 1
fi
/usr/sbin/nginx -v
/usr/sbin/nginx -t
rpm -e nginx >/dev/null 2>&1 || true
echo "==> smoke test passed"

# ---------------------------------------------------------------------------
# 6. 收集产物
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/*.rpm 2>/dev/null || true
find "${TOP_DIR}/RPMS" -name '*.rpm' -exec cp -v {} "${OUT_DIR}/" \;
chmod -R a+rX "$OUT_DIR"

echo "==> rpm contents:"
for f in "${OUT_DIR}"/*.rpm; do
    echo "--- $f"
    rpm -qip "$f"
    rpm -qlp "$f"
done

echo "==> nginx -V (from buildroot):"
"${TOP_DIR}"/BUILDROOT/nginx-*/usr/sbin/nginx -V || true

echo "==> done: $(ls -1 "$OUT_DIR")"
