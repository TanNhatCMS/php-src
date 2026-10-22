#!/bin/bash
# Build PHP 7.4 + backport CVE-2026-109618 / CVE-2026-109619 từ nhánh
# TanNhatCMS/php-src @ PHP-7.4-CVE-2026-109618-109619 trên Ubuntu.
# Đã kiểm chứng trên Ubuntu 24.04 (gcc 13.3, autoconf 2.71, bison 3.8.2, re2c 3.1).
# Chạy:  ./build-linux.sh [thư-mục-cài-đặt]   (mặc định /opt/php74-cve)
set -euo pipefail

PREFIX="${1:-/opt/php74-cve}"
BRANCH="PHP-7.4-CVE-2026-109618-109619"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"   # script nằm trong thư mục source đã clone

echo "==> Cai cong cu + thu vien (can sudo)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential autoconf bison re2c pkg-config \
  libxml2-dev libssl-dev libsqlite3-dev libcurl4-openssl-dev \
  libonig-dev libzip-dev libreadline-dev libsodium-dev

# autoconf 2.72+ làm hỏng buildconf của PHP 7.4 — kiểm tra sớm cho đỡ mất công
AC_VER="$(autoconf --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
awk "BEGIN{exit !($AC_VER > 2.71)}" && {
  echo "LOI: autoconf $AC_VER > 2.71 — cần autoconf 2.68–2.71 cho PHP 7.4" >&2; exit 1; }

cd "$SRC_DIR"
git rev-parse --abbrev-ref HEAD | grep -qx "$BRANCH" || {
  echo "LOI: source không ở nhánh $BRANCH" >&2; exit 1; }
git log -1 --format="%h %s" 712e60f9edfd03f0960fc4fc3c2c375f42b90aa2 >/dev/null 2>&1 || true
echo "==> Commit vá trên cùng:"; git log --oneline -1

echo "==> buildconf"
./buildconf --force

echo "==> configure -> $PREFIX"
# -DRSA_SSLV23_PADDING=2: header OpenSSL mới (Ubuntu 24.04) đã gỡ hằng số này,
# code 7.4 dùng không có #ifdef -> lỗi biên dịch ext/openssl. Xem BUILD-CVE...md mục 2.4.
CFLAGS="-O2 -DRSA_SSLV23_PADDING=2" ./configure --prefix="$PREFIX" \
  --enable-cli --enable-fpm --enable-litespeed --disable-cgi --disable-phpdbg \
  --with-openssl --with-zlib --with-curl --with-sodium --with-readline \
  --enable-mbstring --with-zip --with-sqlite3 --with-pdo-sqlite \
  --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd \
  --enable-bcmath --enable-sockets --enable-pcntl --enable-soap \
  --enable-exif --enable-ftp --enable-opcache

echo "==> make"
make -j"$(nproc)"

echo "==> make install -> $PREFIX"
if [ -w "$(dirname "$PREFIX")" ]; then make install; else sudo make install; fi

echo "==> Kiem tra"
"$PREFIX/bin/php" -v
"$PREFIX/bin/php" -m | tr '\n' ' '; echo
"$PREFIX/sbin/php-fpm" -v
"$PREFIX/bin/lsphp" -v
echo "XONG. Test nhanh các khu vực bản vá chạm tới:"
echo "  cd $SRC_DIR && sapi/cli/php run-tests.php -q Zend/tests ext/session/tests tests/"
