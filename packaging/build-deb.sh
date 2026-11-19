#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 在 Ubuntu 20.04 / 22.04 容器里把源码 tarball 打成 .deb。
# 直接用 dpkg-deb 组装包（不依赖 debhelper / debian 目录），所以
# 同一个脚本在 focal 和 jammy 上都能跑，产物的 glibc 依赖也就是该发行版的。
#
# 必需环境变量：
#   NGINX_VERSION   例如 1.29.0
# 可选环境变量：
#   DIST_DIR        tarball 所在目录，默认 /work/dist
#   OUT_DIR         产物输出目录，默认 /work/out
#   PACKAGING_DIR   packaging/ 目录，默认 /work/packaging
#   NGINX_USER      运行用户，默认 www-data
#   MAINTAINER      包 Maintainer 字段
#   WORK_DIR        构建临时目录，默认 /work/build/deb
# ---------------------------------------------------------------------------
set -euo pipefail

: "${NGINX_VERSION:?NGINX_VERSION is required}"
DIST_DIR="${DIST_DIR:-/work/dist}"
OUT_DIR="${OUT_DIR:-/work/out}"
PACKAGING_DIR="${PACKAGING_DIR:-/work/packaging}"
NGINX_USER="${NGINX_USER:-www-data}"
MAINTAINER="${MAINTAINER:-nginx packager <root@localhost>}"
WORK_DIR="${WORK_DIR:-/work/build/deb}"

SRC_TARBALL="${DIST_DIR}/nginx-${NGINX_VERSION}.tar.gz"

# shellcheck source=/dev/null
. /etc/os-release
CODENAME="${VERSION_CODENAME:-unknown}"
echo "==> nginx ${NGINX_VERSION} / DEB / ${PRETTY_NAME} (${CODENAME})"

if [ ! -f "$SRC_TARBALL" ]; then
    echo "missing source tarball: ${SRC_TARBALL}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 编译依赖
#    libpcre3-dev 给 PCRE1，libpcre2-dev 给新版 nginx 的 PCRE2 探测；
#    两个都装上，configure 命中哪个都能编过，运行时依赖稍后按 ELF 自动算。
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential ca-certificates dpkg-dev \
    libpcre3-dev libpcre2-dev zlib1g-dev libssl-dev libaio-dev

# ---------------------------------------------------------------------------
# 2. 解包 + 编译
# ---------------------------------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
tar -xzf "$SRC_TARBALL" -C "$WORK_DIR"

SRC_DIR="${WORK_DIR}/nginx-${NGINX_VERSION}"
PKGROOT="${WORK_DIR}/pkgroot"

cd "$SRC_DIR"

# shellcheck source=/dev/null
. "${PACKAGING_DIR}/configure-args.sh"
echo "==> configure options:"
printf '    %s\n' "${nginx_configure_args[@]}"

./auto/configure "${nginx_configure_args[@]}"
make -j"$(nproc)"

# ---------------------------------------------------------------------------
# 3. 组装文件树（DESTDIR 安装 + 运行时目录 + unit + logrotate）
# ---------------------------------------------------------------------------
make install DESTDIR="$PKGROOT"
cd "$WORK_DIR"

install -d "${PKGROOT}/usr/lib/nginx/modules"
install -d "${PKGROOT}/etc/nginx/conf.d"
install -d "${PKGROOT}"/var/lib/nginx/tmp/client_body \
           "${PKGROOT}"/var/lib/nginx/tmp/proxy \
           "${PKGROOT}"/var/lib/nginx/tmp/fastcgi \
           "${PKGROOT}"/var/lib/nginx/tmp/uwsgi \
           "${PKGROOT}"/var/lib/nginx/tmp/scgi
install -d "${PKGROOT}/var/log/nginx"

# Ubuntu 20.04+ 的 /lib 是指向 usr/lib 的软链，装到 lib/systemd/system 即可
install -d "${PKGROOT}/lib/systemd/system"
install -m 0644 "${PACKAGING_DIR}/common/nginx.service"   "${PKGROOT}/lib/systemd/system/nginx.service"
install -D -m 0644 "${PACKAGING_DIR}/common/nginx.logrotate" "${PKGROOT}/etc/logrotate.d/nginx"

CONF="${PKGROOT}/etc/nginx/nginx.conf"
# nginx.conf 里的 user 必须和 --user= 一致
sed -i -r "s|^#?user[[:space:]].*|user ${NGINX_USER};|" "$CONF"
# 给 http{} 加 conf.d include
awk '
    /^[[:space:]]*http[[:space:]]*\{/ && !done {
        print
        print "    include /etc/nginx/conf.d/*.conf;"
        done = 1
        next
    }
    { print }
' "$CONF" > "${CONF}.new"
mv "${CONF}.new" "$CONF"

chown -R root:root "$PKGROOT"
chown -R "${NGINX_USER}:${NGINX_USER}" "${PKGROOT}/var/lib/nginx" "${PKGROOT}/var/log/nginx"
chmod 0755 "${PKGROOT}/var/lib/nginx" "${PKGROOT}/var/log/nginx"

# ---------------------------------------------------------------------------
# 4. 生成 DEBIAN/
# ---------------------------------------------------------------------------
ARCH="$(dpkg --print-architecture)"
SIZE="$(du -sk --exclude=DEBIAN "$PKGROOT" | cut -f1)"

# 按 ELF 的 NEEDED 反查所属包，避免把 libssl1.1/libssl3、PCRE1/PCRE2 写死
deps=""
for soname in $(objdump -p "${PKGROOT}/usr/sbin/nginx" | awk '/NEEDED/ {print $2}'); do
    libfile="$(ldconfig -p | awk -v s="$soname" '$1 == s { print $NF; exit }')"
    [ -n "$libfile" ] || continue
    pkg="$(dpkg -S "$libfile" 2>/dev/null | head -n1 | cut -d: -f1)"
    [ -n "$pkg" ] || continue
    case ",${deps}," in
        *",${pkg},"*) continue ;;
    esac
    deps="${deps:+${deps}, }${pkg}"
done
[ -n "$deps" ] || deps="libc6"
echo "==> runtime depends: ${deps}"

mkdir -p "${PKGROOT}/DEBIAN"

cat > "${PKGROOT}/DEBIAN/control" <<EOF
Package: nginx
Version: ${NGINX_VERSION}-1~${CODENAME}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${SIZE}
Depends: ${deps}
Section: httpd
Priority: optional
Homepage: https://nginx.org/
Provides: httpd
Conflicts: nginx-common, nginx-core, nginx-full, nginx-light, nginx-extras
Description: nginx ${NGINX_VERSION} - high performance web server and reverse proxy
 nginx [engine x] is an HTTP and reverse proxy server, a mail proxy server and
 a generic TCP/UDP proxy server.
 .
 This package was built from the nginx source tree for ${PRETTY_NAME}.
EOF

# /etc 下所有文件都按 conffile 处理，升级时不会覆盖用户改过的配置
( cd "$PKGROOT" && find etc -type f | LC_ALL=C sort | sed 's|^|/|' ) > "${PKGROOT}/DEBIAN/conffiles"

for script in postinst prerm postrm; do
    install -m 0755 "${PACKAGING_DIR}/deb/${script}" "${PKGROOT}/DEBIAN/${script}"
done

( cd "$PKGROOT" \
  && find . -type f ! -path './DEBIAN/*' -print0 \
     | LC_ALL=C sort -z \
     | xargs -0 md5sum \
     | sed 's|\./||' ) > "${PKGROOT}/DEBIAN/md5sums"

chmod 0644 "${PKGROOT}/DEBIAN/control" "${PKGROOT}/DEBIAN/conffiles" "${PKGROOT}/DEBIAN/md5sums"

# ---------------------------------------------------------------------------
# 5. 出包
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/*.deb 2>/dev/null || true

DEB_FILE="${OUT_DIR}/nginx_${NGINX_VERSION}-1~${CODENAME}_${ARCH}.deb"
dpkg-deb --build "$PKGROOT" "$DEB_FILE"
chmod -R a+rX "$OUT_DIR"

# ---------------------------------------------------------------------------
# 6. 冒烟测试：在同一个容器里真的装上，验证文件树和 maintainer scripts
# ---------------------------------------------------------------------------
echo "==> smoke test: installing ${DEB_FILE}"
if ! dpkg -i "$DEB_FILE" > /tmp/nginx-deb-install.log 2>&1; then
    echo "dpkg -i of the built package failed:" >&2
    cat /tmp/nginx-deb-install.log >&2
    exit 1
fi
/usr/sbin/nginx -v
/usr/sbin/nginx -t
dpkg -r nginx >/dev/null 2>&1 || true
echo "==> smoke test passed"

echo "==> package info:"
dpkg-deb -I "$DEB_FILE"
echo "==> package contents:"
dpkg-deb -c "$DEB_FILE"

echo "==> nginx -V (from staging tree):"
"${PKGROOT}/usr/sbin/nginx" -V || true

echo "==> done: $(ls -1 "$OUT_DIR")"
