#!/bin/bash
# Build PHP 8.0 + backport CVE-2026-109618 / CVE-2026-109619 từ nhánh
# TanNhatCMS/php-src @ PHP-8.0-CVE-2026-109618-109619 trên macOS (Apple Silicon).
# Công thức đúng với bản CI đã build xanh trên macos-14 ARM64 — xem
# BUILD-CVE-2026-109618-109619.md mục 3 (và 5.1 về ba cái bẫy macOS).
# Chạy:  ./build-macos.sh [thư-mục-cài-đặt]   (mặc định ~/php80-cve)
# Chạy được 2 kiểu: (a) script nằm trong thư mục source đã clone — build tại chỗ;
# (b) chạy độc lập ở bất kỳ đâu — tự clone repo, checkout đúng nhánh rồi gọi lại
# chính nó trong cây source. Build xong là CÀI LUÔN vào [thư-mục-cài-đặt].
set -euo pipefail

PREFIX="${1:-$HOME/php80-cve}"
BRANCH="PHP-8.0-CVE-2026-109618-109619"
REPO_URL="https://github.com/TanNhatCMS/php-src.git"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Bootstrap: chưa ở trong cây source thì clone + checkout rồi exec bản trong cây
if [ ! -f "$SELF_DIR/configure.ac" ]; then
  SRC_DIR="${SRC_DIR:-$PWD/php-src}"
  echo "==> Clone $REPO_URL -> $SRC_DIR"
  [ -d "$SRC_DIR/.git" ] || git clone "$REPO_URL" "$SRC_DIR"
  git -C "$SRC_DIR" fetch origin "$BRANCH"
  git -C "$SRC_DIR" checkout "$BRANCH"
  git -C "$SRC_DIR" pull --ff-only origin "$BRANCH" || true
  exec "$SRC_DIR/build-macos.sh" "$@"
fi
SRC_DIR="$SELF_DIR"
cd "$SRC_DIR"
git rev-parse --abbrev-ref HEAD | grep -qx "$BRANCH" || {
  echo "LOI: source không ở nhánh $BRANCH" >&2; exit 1; }
echo "==> Commit vá trên cùng:"; git log --oneline -1

# --- 1) Deps qua Homebrew. KHÔNG cài libxml2 của brew (2.14+ đổi chữ ký API,
# dùng libxml2 2.9.13 đi kèm macOS SDK như công thức CI đã kiểm chứng.
command -v brew >/dev/null 2>&1 || { echo "LOI: cần Homebrew (https://brew.sh)" >&2; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
       HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1
echo "==> brew install deps"
brew install bison pkg-config libtool m4 openssl@3 \
  sqlite libzip oniguruma libsodium curl readline libiconv

# Canh libxml2: xml2-config mà configure sẽ gặp phải là bản 2.9.x của SDK.
# Nếu máy đã cài libxml2 của brew và nó đang link, xml2-config trỏ sang bản mới -> dừng sớm.
XML2_VER="$(xml2-config --version 2>/dev/null || echo none)"
case "$XML2_VER" in
  2.9.*) echo "==> libxml2: $XML2_VER (SDK, đúng dòng SDK)" ;;
  *) echo "LOI: xml2-config đang trỏ libxml2 $XML2_VER. Cần bản 2.9.x của macOS SDK:" >&2
     echo "     brew unlink libxml2   # gỡ link (không cần gỡ cài đặt) rồi chạy lại" >&2
     exit 1 ;;
esac

# --- 2) Ghim autoconf 2.71 + re2c 3.1 từ tarball chính thức (brew ship
# autoconf 2.73 + re2c 4.6, ngoài dải buildconf của PHP 8.0 chịu được).
# Cache ở ~/.php80-tools, build 1 lần cho mọi lần chạy sau.
TOOLS="$HOME/.php80-tools"
if [ ! -x "$TOOLS/bin/autoconf" ] || [ ! -x "$TOOLS/bin/re2c" ]; then
  echo "==> Build autoconf 2.71 + re2c 3.1 -> $TOOLS"
  mkdir -p "$TOOLS/src"
  cd "$TOOLS/src"
  [ -f autoconf-2.71.tar.gz ] || curl -fsSL -O https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.gz
  [ -d autoconf-2.71 ] || tar xzf autoconf-2.71.tar.gz
  ( cd autoconf-2.71 && M4="$(brew --prefix m4)/bin/m4" ./configure --prefix="$TOOLS" >/dev/null && make -s && make -s install )
  [ -f re2c-3.1.tar.xz ] || curl -fsSL -O https://github.com/skvadrik/re2c/releases/download/3.1/re2c-3.1.tar.xz
  [ -d re2c-3.1 ] || tar xJf re2c-3.1.tar.xz
  ( cd re2c-3.1 && ./configure --prefix="$TOOLS" >/dev/null && make -s && make -s install )
  cd "$SRC_DIR"
fi
export PHP_AUTOCONF="$TOOLS/bin/autoconf"
# Các gói keg-only phải đưa vào PATH/PKG_CONFIG_PATH thủ công
export PATH="$TOOLS/bin:$(brew --prefix bison)/bin:$(brew --prefix m4)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix curl)/lib/pkgconfig:$(brew --prefix libzip)/lib/pkgconfig:$(brew --prefix sqlite)/lib/pkgconfig:$(brew --prefix readline)/lib/pkgconfig"
echo "==> Tools: $("$PHP_AUTOCONF" --version | head -1); re2c $(re2c --version); bison $(bison --version | head -1)"

# --- 3) Build. Hệ thống build tiền-Apple-Silicon của PHP 8.0 không biết
# /opt/homebrew nên phải truyền thẳng prefix brew cho từng --with-*;
# clang mới biến implicit-function-declaration thành lỗi cứng -> hạ xuống warning.
echo "==> buildconf"
./buildconf --force

echo "==> configure -> $PREFIX"
export CPPFLAGS="-I$(brew --prefix)/include"
export LDFLAGS="-L$(brew --prefix)/lib"
CFLAGS="-O2 -DRSA_SSLV23_PADDING=2 -Wno-implicit-function-declaration -Wno-implicit-int" \
./configure --prefix="$PREFIX" \
  --enable-cli --enable-fpm --enable-litespeed --disable-cgi --disable-phpdbg \
  --with-openssl="$(brew --prefix openssl@3)" --with-zlib \
  --with-iconv="$(brew --prefix libiconv)" \
  --with-curl="$(brew --prefix curl)" \
  --with-sodium="$(brew --prefix libsodium)" \
  --with-readline="$(brew --prefix readline)" \
  --enable-mbstring --with-zip="$(brew --prefix libzip)" \
  --with-sqlite3="$(brew --prefix sqlite)" --with-pdo-sqlite \
  --enable-bcmath --enable-sockets --enable-pcntl --enable-soap \
  --enable-exif --enable-ftp --enable-opcache

echo "==> make"
make -j"$(sysctl -n hw.ncpu)"

echo "==> make install -> $PREFIX"
if [ -w "$(dirname "$PREFIX")" ]; then make install; else sudo make install; fi

echo "==> Kiem tra"
"$PREFIX/bin/php" -v
"$PREFIX/bin/php" -m | tr '\n' ' '; echo
"$PREFIX/sbin/php-fpm" -v
"$PREFIX/bin/lsphp" -v
nm "$PREFIX/bin/php" | grep -q "zend_mm_safe_error_ex" \
  && echo "OK: symbol zend_mm_safe_error_ex (của bản vá) có trong binary" \
  || { echo "LOI: không thấy symbol của bản vá trong binary" >&2; exit 1; }
echo "XONG. PHP 8.0.31 (đã vá CVE-2026-109618/109619) đã cài tại $PREFIX"
