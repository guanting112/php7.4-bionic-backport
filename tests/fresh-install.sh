#!/bin/bash
# Fresh install on a clean ubuntu:18.04, using the bundled php-common.
#
#   docker run --rm -v "$PWD/<dir>:/debs:ro" -v "$PWD/tests:/tests:ro" \
#     ubuntu:18.04 bash /tests/fresh-install.sh /debs
#
# Prints PHP_V=<first line of php -v> and RESULT=PASS on success.

. "$(dirname "$0")/lib.sh"
src=${1:?usage: $0 <directory with the .deb files>}

work=$(mktemp -d)
cp -r "$src"/. "$work"/
cd "$work"
want=$(dpkg-deb -f php7.4-common_*.deb Version)
echo "=== fresh install of $want"

# --- README: Fresh install (plus -y) ---
sha256sum -c --ignore-missing SHA256SUMS >/dev/null || fail "SHA256SUMS"
sudo apt-get update -qq >/dev/null || fail "apt-get update"
sudo apt-get install -y ./php-common_*.deb \
  ./php7.4-{common,json,opcache,readline,cli,fpm,mysql,mbstring,xml,curl,gd,zip,bcmath,intl}_*.deb \
  </dev/null >/tmp/fresh.log 2>&1 || { tail -40 /tmp/fresh.log; fail "install"; }

check_apt_log /tmp/fresh.log
check_php "$want"
php -m | tr '\n' ' '; echo
echo "PHP_V=$(php -v | head -1)"
echo "RESULT=PASS"
