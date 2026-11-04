#!/usr/bin/env bash
set -euo pipefail

tag="$1"
out="$2"
src="$(mktemp -d)"

git clone -q --depth 1 --branch "$tag" https://github.com/GrapheneOS/platform_external_selinux "$src"
make -s -C "$src/libsepol/src" libsepol.a CFLAGS="-O2 -std=gnu11"
mkdir -p "$src/inc/sepol"
ln -s "$src/libsepol/cil/include/cil" "$src/inc/sepol/cil"
gcc -O2 -std=gnu11 -I"$src/inc" -I"$src/libsepol/include" -I"$src/libsepol/cil/include" \
    -o "$out" "$src/secilc/secilc.c" "$src/libsepol/src/libsepol.a"
rm -rf "$src"
