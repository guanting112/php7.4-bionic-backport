#!/bin/bash
# Upgrade OLD -> NEW and roll back NEW -> OLD with the README commands, on a
# clean ubuntu:18.04, and check that edited config files survive both steps.
#
#   docker run --rm -v "$PWD/dist:/dist:ro" -v "$PWD/tests:/tests:ro" \
#     ubuntu:18.04 bash /tests/upgrade-rollback.sh /dist/<old> /dist/<new>
#
# Prints RESULT=PASS on success.

. "$(dirname "$0")/lib.sh"
old_src=${1:?usage: $0 <old directory> <new directory>}
new_src=${2:?usage: $0 <old directory> <new directory>}

mkdir -p /root/old /root/new
cp -r "$old_src"/. /root/old/
cp -r "$new_src"/. /root/new/
old_ver=$(dpkg-deb -f /root/old/php7.4-common_*.deb Version)
new_ver=$(dpkg-deb -f /root/new/php7.4-common_*.deb Version)
dpkg --compare-versions "$new_ver" gt "$old_ver" || fail "$new_ver is not newer than $old_ver"

sudo apt-get update -qq >/dev/null || fail "apt-get update"

echo "=== [1] install $old_ver, including the Apache module and the php7.4 metapackage"
cd /root/old
common=$(ls /root/old/php-common_*.deb /root/new/php-common_*.deb 2>/dev/null | head -1)
# shellcheck disable=SC2046
apt-get install -y "$common" $(pkg_list .) ./libapache2-mod-php7.4_*.deb ./php7.4_*_all.deb ./php7.4-xsl_*.deb \
  </dev/null >/tmp/old.log 2>&1 || { tail -40 /tmp/old.log; fail "install $old_ver"; }
check_php "$old_ver"

# Edit config files the way an operator would
sed -i 's/^memory_limit = .*/memory_limit = 333M/' /etc/php/7.4/fpm/php.ini
sed -i 's/^pm.max_children = .*/pm.max_children = 33/' /etc/php/7.4/fpm/pool.d/www.conf
check_config() {
  grep -q '^memory_limit = 333M' /etc/php/7.4/fpm/php.ini || fail "edited php.ini was lost ($1)"
  grep -q '^pm.max_children = 33' /etc/php/7.4/fpm/pool.d/www.conf || fail "edited www.conf was lost ($1)"
}

echo "=== [2] upgrade to $new_ver"
# --- README: Upgrade an existing PHP 7.4 install (plus -y) ---
cd /root/new
sha256sum -c --ignore-missing SHA256SUMS >/dev/null || fail "SHA256SUMS (new)"
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' php-common)" ge 1:81~ && echo "php-common OK" || fail "php-common check"
sudo cp -a /etc/php/7.4 /root/etc-php-7.4.bak-$(date +%F)
pk=$(for f in *.deb; do n=${f%%_*}; [ "$n" = php-common ] && continue; dpkg-query -W -f='${Status}' "$n" 2>/dev/null | grep -q 'ok installed' && echo "./$f"; done)
echo "$pk"
echo "$pk" | grep -q php-common && fail "php-common was selected"
sudo UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::=--force-confold $pk \
  </dev/null >/tmp/upgrade.log 2>&1 || { tail -40 /tmp/upgrade.log; fail "upgrade"; }

check_apt_log /tmp/upgrade.log
check_php "$new_ver"
for p in libapache2-mod-php7.4 php7.4 php7.4-xsl; do
  [ "$(dpkg-query -W -f='${Version}' "$p")" = "$new_ver" ] || fail "$p was not upgraded"
done
check_config upgrade

echo "=== [3] roll back to $old_ver"
# --- README: Roll back (plus -y) ---
cd /root/old
sha256sum -c --ignore-missing SHA256SUMS >/dev/null || fail "SHA256SUMS (old)"
pk=$(for f in *.deb; do n=${f%%_*}; [ "$n" = php-common ] && continue; dpkg-query -W -f='${Status}' "$n" 2>/dev/null | grep -q 'ok installed' && echo "./$f"; done)
echo "$pk"
sudo UCF_FORCE_CONFFOLD=1 apt-get install -y --allow-downgrades -o Dpkg::Options::=--force-confold $pk \
  </dev/null >/tmp/rollback.log 2>&1 || { tail -40 /tmp/rollback.log; fail "rollback"; }

check_apt_log /tmp/rollback.log
check_php "$old_ver"
for p in libapache2-mod-php7.4 php7.4 php7.4-xsl; do
  [ "$(dpkg-query -W -f='${Version}' "$p")" = "$old_ver" ] || fail "$p was not rolled back"
done
check_config rollback

echo "RESULT=PASS"
