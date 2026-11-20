#!/usr/bin/env bash
# Rebuild Ondřej Surý's PPA php7.4 source package as .deb files for
# Ubuntu 18.04 (bionic), inside an ubuntu:18.04 Docker container.
#
# Run as root on any amd64 Ubuntu host (e.g. 22.04 / 24.04). The host release
# does not matter: the packages link against the container's 18.04 libraries.
#
#   ./build-php74-bionic.sh                      # latest php7.4 revision on the PPA (jammy)
#   PHP74_REVISION=31 ./build-php74-bionic.sh    # a specific revision: 1:7.4.33-31
#   SOURCE_ONLY=1 ./build-php74-bionic.sh        # only download + verify the source into $WORK_DIR/src
#   OUT_DIR=/root/out ./build-php74-bionic.sh
#
# Output: $OUT_DIR (default /root/php74-bionic-debs)
#   - php7.4-*   main packages, versioned 1:7.4.33-NN+ubuntu18.04.1+local1
#   - php-common only needed when the target has no php-common, or one older
#                than php7.4-common requires (>= 1:81~).
#                php-defaults also builds php, php-mysql, ... metapackages that
#                point at PHP 8.x. They are not copied to $OUT_DIR.
#   - *.buildinfo, *.changes, SHA256SUMS
#
# Takes about 15 minutes on 8 cores (about 11 of them compiling php7.4).
#
# How the source is verified:
#   - apt-get source fetches the current revision, checked by apt through the
#     PPA's signed index.
#   - The .dsc signing key is trusted only after it is shown to have signed that
#     apt-verified .dsc.
#   - Older revisions are no longer in the index, so their .dsc is fetched from
#     the PPA pool.
#   - Either way, dpkg-source requires a valid .dsc signature and checks every
#     file's checksum.

set -euo pipefail

OUT_DIR="${OUT_DIR:-/root/php74-bionic-debs}"
WORK_DIR="${WORK_DIR:-/root/php74-build}"
CONTAINER="${CONTAINER:-php74-bionic-build}"
PHP74_REVISION="${PHP74_REVISION:-}"
SOURCE_ONLY="${SOURCE_ONLY:-0}"
# Appended to the PPA's Debian revision, e.g. 1:7.4.33-37 -> 1:7.4.33-37+ubuntu18.04.1+local1
LOCAL_SUFFIX="${LOCAL_SUFFIX:-+ubuntu18.04.1+local1}"
# Ondřej Surý PPA archive signing key (InRelease)
PPA_KEY_FPR="14AA40EC0831756756D7F66C4F4EA0AAE5267A6C"
# Ondřej Surý (Automated PPA Upload Key), signs the .dsc files
DSC_KEY_FPR="6A1AAD7AE5B401C6E259A7B257067BAA1314C7FC"

if [ -n "$PHP74_REVISION" ] && ! [[ "$PHP74_REVISION" =~ ^[0-9]+$ ]]; then
  echo "PHP74_REVISION must be a number, e.g. 37 (got: $PHP74_REVISION)" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  systemctl enable --now docker
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"

cat > "$WORK_DIR/inner.sh" <<'INNER'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
export DEBFULLNAME="Local backport build" DEBEMAIL="root@localhost"
POOL=https://ppa.launchpadcontent.net/ondrej/php/ubuntu/pool/main/p/php7.4

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential devscripts equivs dpkg-dev fakeroot wget ca-certificates gnupg dirmngr

# fetch_key FINGERPRINT KEYRING: download a key and refuse anything but exactly that key
fetch_key() {
  wget -qO /tmp/key.asc "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$1"
  gpg --batch --quiet --yes --dearmor -o "$2" /tmp/key.asc
  local listing
  listing=$(gpg --batch --no-default-keyring --keyring "$2" --list-keys --with-colons)
  [ "$(grep -c '^pub:' <<<"$listing")" = 1 ] || { echo "Expected exactly one key in $2"; exit 1; }
  [ "$(awk -F: '/^fpr/{print $10; exit}' <<<"$listing")" = "$1" ] || { echo "Key fingerprint mismatch for $1"; exit 1; }
}

fetch_key "$PPA_KEY_FPR" /usr/share/keyrings/ondrej-php.gpg
echo "deb-src [signed-by=/usr/share/keyrings/ondrej-php.gpg] http://ppa.launchpadcontent.net/ondrej/php/ubuntu jammy main" \
  > /etc/apt/sources.list.d/ondrej-src.list
apt-get update -qq

cd /build
rm -rf src pool php7.4_* ./*.deb ./*.buildinfo ./*.changes
# Current php7.4 source on the PPA, verified by apt through the signed index
apt-get source --download-only php7.4
dsc=$(ls -1 php7.4_*.dsc | sort -V | tail -1)
current=$(awk '/^Version: /{print $2; exit}' "$dsc")    # 1:7.4.33-37+ubuntu22.04.1+deb.sury.org+1
echo "Current PPA version: $current"

want="$current"
if [ -n "${PHP74_REVISION:-}" ]; then
  want="1:7.4.33-${PHP74_REVISION}+ubuntu22.04.1+deb.sury.org+1"
fi

# The .dsc signing key is trusted only because it also signed the apt-verified current .dsc
mkdir -p -m 700 /root/.gnupg
fetch_key "$DSC_KEY_FPR" /root/.gnupg/trustedkeys.gpg
gpgv --keyring /root/.gnupg/trustedkeys.gpg "$dsc"

if [ "$want" != "$current" ]; then
  # Older revision: no longer in the index, so fetch it from the pool
  v="${want#1:}"
  mkdir pool && cd pool
  wget -q "$POOL/php7.4_${v}.dsc"
  gpgv --keyring /root/.gnupg/trustedkeys.gpg "php7.4_${v}.dsc"
  for f in $(awk '/^Checksums-Sha256:/{f=1; next} f && /^ /{print $3; next} f{exit}' "php7.4_${v}.dsc"); do
    wget -q "$POOL/$f"
  done
  cd ..
  dsc="pool/php7.4_${v}.dsc"
fi

# Checks the .dsc signature and every file's checksum against it
dpkg-source --require-valid-signature -x "$dsc" src

[ "$(dpkg-parsechangelog -l src/debian/changelog -S Version)" = "$want" ] || { echo "Extracted source is not $want"; exit 1; }

if [ "$SOURCE_ONLY" = 1 ]; then
  echo "Source for $want verified and extracted to /build/src"
  exit 0
fi

cd src
apt-get build-dep -y ./

upstream_ver=$(dpkg-parsechangelog -S Version)          # 1:7.4.33-37+ubuntu22.04.1+deb.sury.org+1
new_ver="${upstream_ver%%+*}${LOCAL_SUFFIX}"             # 1:7.4.33-37+ubuntu18.04.1+local1
# -b: "ubuntu18.04" sorts lower than "ubuntu22.04", so dch needs to be forced
dch -b -v "$new_ver" -D bionic --force-distribution "Rebuild of ${upstream_ver} for Ubuntu 18.04 (bionic)."

date -u +"BUILD START %FT%TZ"
DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck" dpkg-buildpackage -b -us -uc
date -u +"BUILD END %FT%TZ"

# php-common (from the php-defaults source package). The one in the 18.04
# archive is too old to satisfy php7.4-common.
mkdir -p /build/php-defaults && cd /build/php-defaults && rm -rf ./*
apt-get source --download-only php-defaults
dsc=$(ls -1 php-defaults_*.dsc | sort -V | tail -1)
dpkg-source -x "$dsc" src
cd src
apt-get build-dep -y ./
upstream_ver=$(dpkg-parsechangelog -S Version)
dch -b -v "${upstream_ver%%+*}${LOCAL_SUFFIX}" -D bionic --force-distribution "Rebuild of ${upstream_ver} for Ubuntu 18.04 (bionic)."
dpkg-buildpackage -b -us -uc
INNER
chmod +x "$WORK_DIR/inner.sh"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run --rm --name "$CONTAINER" --platform linux/amd64 \
  -e PPA_KEY_FPR="$PPA_KEY_FPR" -e DSC_KEY_FPR="$DSC_KEY_FPR" -e LOCAL_SUFFIX="$LOCAL_SUFFIX" \
  -e PHP74_REVISION="$PHP74_REVISION" -e SOURCE_ONLY="$SOURCE_ONLY" \
  -v "$WORK_DIR:/build" ubuntu:18.04 /build/inner.sh 2>&1 | tee "$WORK_DIR/build.log"

if [ "$SOURCE_ONLY" = 1 ]; then
  echo "Done. Verified source is in $WORK_DIR/src"
  exit 0
fi

cp -v "$WORK_DIR"/*.deb "$WORK_DIR"/*.buildinfo "$WORK_DIR"/*.changes "$WORK_DIR"/php-defaults/php-common_*.deb "$OUT_DIR"/
(cd "$OUT_DIR" && sha256sum ./*.deb > SHA256SUMS)
echo "Done. Packages are in $OUT_DIR"
