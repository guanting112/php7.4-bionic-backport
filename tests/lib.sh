# Shared helpers for the install tests. Sourced, not executed.
# The tests run as root inside a clean ubuntu:18.04 container.

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

fail() { echo "FAIL: $*"; echo "RESULT=FAIL"; exit 1; }

# The README commands use sudo. We are already root; env handles VAR=value like sudo does.
sudo() { env "$@"; }

# Same extension set for every test
EXTS="bcmath cli common curl fpm gd intl json mbstring mysql opcache readline xml zip"

# check_php VERSION: the installed build is VERSION and works
check_php() {
  local want=$1 p out
  for p in php7.4-cli php7.4-fpm php7.4-common; do
    [ "$(dpkg-query -W -f='${Version}' "$p")" = "$want" ] || fail "$p is not $want"
  done
  php -v | head -1
  php-fpm7.4 -t 2>&1 | grep -q 'test is successful' || fail "php-fpm7.4 -t"
  out=$(php -r 'echo mb_strlen("中文"),
    function_exists("imagecreate") ? " gd" : "",
    function_exists("curl_init") ? " curl" : "",
    " ", bcadd("1", "2"),
    extension_loaded("pdo_mysql") ? " pdo_mysql" : "",
    class_exists("Normalizer") ? " intl" : "",
    password_verify("x", password_hash("x", PASSWORD_ARGON2ID)) ? " argon2id" : "";')
  [ "$out" = "2 gd curl 3 pdo_mysql intl argon2id" ] || fail "extension check: $out"
}

# check_apt_log FILE: apt removed nothing and dpkg asked no config-file question
check_apt_log() {
  grep -q 'REMOVED' "$1" && fail "apt removed packages (see $1)"
  grep -q '(Y/I/N/O/D/Z)' "$1" && fail "dpkg asked about a config file (see $1)"
  return 0
}

# pkg_list DIR: ./php7.4-<ext>_*.deb for every extension in $EXTS
pkg_list() {
  local e
  for e in $EXTS; do ls "$1"/php7.4-"${e}"_*.deb; done
}
