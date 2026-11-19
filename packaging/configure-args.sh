#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 所有包格式共用的 nginx ./configure 参数。
#
# 由 packaging/build-rpm.sh 和 packaging/build-deb.sh 通过 source 引入：
#
#   . "$PACKAGING_DIR/configure-args.sh"
#   ./auto/configure "${nginx_configure_args[@]}"
#
# 想改模块清单、安装路径、编译选项，只改这一个文件即可。
# 也可以在命令行覆盖，例如：
#   NGINX_USER=nginx NGINX_CC_OPT="-O2 -march=native" bash packaging/build-rpm.sh
# ---------------------------------------------------------------------------

: "${NGINX_VERSION:?NGINX_VERSION must be set before sourcing configure-args.sh}"
NGINX_USER="${NGINX_USER:-nginx}"

# 安装布局、systemd、日志路径尽量对齐官方 nginx 包，方便直接从官方文档抄配置。
case "${NGINX_USER}" in
    www-data) NGINX_MODULES_PATH="/usr/lib/nginx/modules" ;;
    *)        NGINX_MODULES_PATH="/usr/lib64/nginx/modules" ;;
esac

NGINX_CC_OPT="${NGINX_CC_OPT:--O2 -g -fstack-protector-strong -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2}"
NGINX_LD_OPT="${NGINX_LD_OPT:--Wl,-z,relro -Wl,-z,now}"

nginx_configure_args=(
    # --- 安装路径 -----------------------------------------------------------
    --prefix=/usr/share/nginx
    --sbin-path=/usr/sbin/nginx
    --modules-path="${NGINX_MODULES_PATH}"
    --conf-path=/etc/nginx/nginx.conf
    --pid-path=/run/nginx.pid
    --lock-path=/run/nginx.lock
    --error-log-path=/var/log/nginx/error.log
    --http-log-path=/var/log/nginx/access.log
    --http-client-body-temp-path=/var/lib/nginx/tmp/client_body
    --http-proxy-temp-path=/var/lib/nginx/tmp/proxy
    --http-fastcgi-temp-path=/var/lib/nginx/tmp/fastcgi
    --http-uwsgi-temp-path=/var/lib/nginx/tmp/uwsgi
    --http-scgi-temp-path=/var/lib/nginx/tmp/scgi
    --user="${NGINX_USER}"
    --group="${NGINX_USER}"

    # --- 基础能力 -----------------------------------------------------------
    --with-threads
    --with-file-aio

    # --- http 模块（全部不额外依赖第三方库）--------------------------------
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module
    --with-http_addition_module
    --with-http_sub_module
    --with-http_dav_module
    --with-http_flv_module
    --with-http_mp4_module
    --with-http_gunzip_module
    --with-http_gzip_static_module
    --with-http_auth_request_module
    --with-http_random_index_module
    --with-http_secure_link_module
    --with-http_slice_module
    --with-http_stub_status_module

    # --- stream（四层 TCP/UDP 代理）----------------------------------------
    --with-stream
    --with-stream_realip_module
    --with-stream_ssl_module
    --with-stream_ssl_preread_module

    # --- 编译/链接加固 ------------------------------------------------------
    --with-cc-opt="${NGINX_CC_OPT}"
    --with-ld-opt="${NGINX_LD_OPT}"
)

# 需要额外 *-dev / *-devel 包才能开的模块，装好依赖后把对应参数加进上面的数组：
#   --with-http_xslt_module          (libxslt1-dev / libxslt-devel)
#   --with-http_image_filter_module  (libgd-dev    / gd-devel)
#   --with-http_geoip_module         (libgeoip-dev / GeoIP-devel)
#
# 故意不启用的参数：
#   --with-pcre-jit   系统自带 PCRE 未必编了 JIT，configure 会直接失败
#   --with-compat     只对动态模块有意义，静态编译用不上
