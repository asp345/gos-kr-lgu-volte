#!/usr/bin/env bash
set -euo pipefail

input="$(realpath "$1")"
output="$(realpath -m "$2")"
work="$3"
patch_dir="$(realpath "$(dirname "$0")/../patch")"
keys_dir="$(realpath "$(dirname "$0")/../keys")"

: "${KEY_AVB:?}" "${KEY_OTA:?}" "${PASSPHRASE_AVB:?}" "${PASSPHRASE_OTA:?}" "${EXPECTED_AVB_KEY_SHA256:?}"
KEY_AVB="$(realpath "$KEY_AVB")"
KEY_OTA="$(realpath "$KEY_OTA")"

mkdir -p "$work" "$(dirname "$output")"
cd "$work"

avbroot ota verify --input "$input"
avbroot ota extract --input "$input" --directory . --none --public-key-avb input_avb_pkmd.bin
echo "$EXPECTED_AVB_KEY_SHA256  input_avb_pkmd.bin" | sha256sum -c -

unpack() {
    avbroot ota extract --input "$input" --directory . --partition "$1"
    mkdir "$1"
    (cd "$1" && avbroot avb unpack -q -i "../$1.img" && afsr unpack -i raw.img && rm raw.img)
    rm "$1.img"
}

pack() {
    (cd "$1" && afsr pack -o raw.img && rm -rf fs_tree && avbroot avb pack -q -o "../$1.img" --recompute-size && rm raw.img)
}

for p in vendor system system_ext product; do
    unpack "$p"
done

S=system/fs_tree/system/etc/selinux
E=system_ext/fs_tree/etc/selinux
P=product/fs_tree/etc/selinux
V=vendor/fs_tree/etc/selinux
vers="$(cat "$V/plat_sepolicy_vers.txt")"
R="$PWD/system/fs_tree/system"
chmod 755 "$R/bin/bootstrap/linker64" "$R/bin/secilc"

compile_sepolicy() {
    local args=("$S/plat_sepolicy.cil" -m -M true -G -N -c 30 "$S/mapping/$vers.cil" -o "$2" -f /dev/null)
    local f
    for f in "$S/mapping/$vers.compat.cil" "$E/system_ext_sepolicy.cil" "$E/mapping/$vers.cil" \
        "$E/mapping/$vers.compat.cil" "$P/product_sepolicy.cil" "$P/mapping/$vers.cil"; do
        [ -f "$f" ] && args+=("$f")
    done
    args+=("$V/plat_pub_versioned.cil" "$1")
    f="$S/plat_sepolicy_genfs_$(cat "$V/genfs_labels_version.txt").cil"
    [ -f "$f" ] && args+=("$f")
    LD_LIBRARY_PATH="$R/lib64/bootstrap" "$R/bin/bootstrap/linker64" "$R/bin/secilc" "${args[@]}"
}

compile_sepolicy "$V/vendor_sepolicy.cil" sepolicy.orig
cmp sepolicy.orig "$V/precompiled_sepolicy"
rm sepolicy.orig

install -m 755 "$patch_dir/write_at_cmd.sh" vendor/fs_tree/bin/write_at_cmd.sh
install -m 644 "$patch_dir/write_at_cmd.rc" vendor/fs_tree/etc/init/write_at_cmd.rc
cat "$patch_dir/fs_entries.toml" >> vendor/fs_metadata.toml
sed "s/@VERS@/$vers/g" "$patch_dir/write_at_cmd.cil" >> "$V/vendor_sepolicy.cil"
printf '\n/vendor/bin/write_at_cmd.sh   u:object_r:write_at_cmd_exec:s0\n' >> "$V/vendor_file_contexts"
compile_sepolicy "$V/vendor_sepolicy.cil" "$V/precompiled_sepolicy"

rm -rf system/fs_tree/system/priv-app/Updater
awk -v dir=/system/priv-app/Updater '
    function flush() { if (!skip) printf "%s", buf; buf = ""; skip = 0 }
    /^\[\[entries\]\]$/ { flush() }
    /^path = "/ { p = substr($0, 9, length($0) - 9); if (p == dir || index(p, dir "/") == 1) skip = 1 }
    { buf = buf $0 "\n" }
    END { flush() }
' system/fs_metadata.toml > system/fs_metadata.toml.new
mv system/fs_metadata.toml.new system/fs_metadata.toml

rm -rf system_ext product
pack vendor
pack system

avbroot ota patch \
    --input "$input" \
    --output "$output" \
    --replace vendor vendor.img \
    --replace system system.img \
    --rootless \
    --key-avb "$KEY_AVB" --pass-avb-env-var PASSPHRASE_AVB \
    --key-ota "$KEY_OTA" --pass-ota-env-var PASSPHRASE_OTA \
    --cert-ota "$keys_dir/ota.crt"
rm -rf vendor system vendor.img system.img

avbroot ota verify --input "$output" --cert-ota "$keys_dir/ota.crt" --public-key-avb "$keys_dir/avb_pkmd.bin"
