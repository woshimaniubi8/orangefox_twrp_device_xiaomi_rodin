#!/usr/bin/env bash
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOP_DIR="$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)"
PRODUCT_OUT="${1:-${OUT_DIR:-${TOP_DIR}/out}/target/product/rodin}"
FIRMWARE_VARIANT="${RODIN_FIRMWARE_VARIANT:-cn}"

case "${FIRMWARE_VARIANT}" in
    cn)
        STOCK_RAMDISK="${DEVICE_DIR}/prebuilt/vendor_ramdisk00"
        STOCK_RAMDISK_SHA256="192977d50a121f7a5ddfab0212488ef0dbb0326cad802ce9d664649967a9845c"
        DEFAULT_OUTPUT_IMAGE="${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin-system-compatible.img"
        DEFAULT_DISABLE_AVB_OUTPUT_IMAGE="${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin-disable-avb-system-compatible.img"
        ;;
    global)
        STOCK_RAMDISK="${DEVICE_DIR}/prebuilt/global/vendor_ramdisk00"
        STOCK_RAMDISK_SHA256="349cc6598f70ae401afe3071abed6de00815af39c5aded3551cff23364208731"
        DEFAULT_OUTPUT_IMAGE="${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin-global-system-compatible.img"
        DEFAULT_DISABLE_AVB_OUTPUT_IMAGE="${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin-global-disable-avb-system-compatible.img"
        ;;
    *)
        echo "unsupported RODIN_FIRMWARE_VARIANT: ${FIRMWARE_VARIANT} (expected cn or global)" >&2
        exit 1
        ;;
esac

OUTPUT_IMAGE="${2:-${DEFAULT_OUTPUT_IMAGE}}"
DISABLE_AVB_OUTPUT_IMAGE="${3:-${DEFAULT_DISABLE_AVB_OUTPUT_IMAGE}}"
STOCK_DTB="${DEVICE_DIR}/prebuilt/dtb/mt6899-rodin.dtb"
RECOVERY_LZ4="${PRODUCT_OUT}/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
LZ4="${PRODUCT_OUT%/target/product/rodin}/host/linux-x86/bin/lz4"
MKBOOTIMG="${PRODUCT_OUT%/target/product/rodin}/host/linux-x86/bin/mkbootimg"
MKBOOTFS="${PRODUCT_OUT%/target/product/rodin}/host/linux-x86/bin/mkbootfs"
AVBTOOL="${PRODUCT_OUT%/target/product/rodin}/host/linux-x86/bin/avbtool"
UNPACK_BOOTIMG="${TOP_DIR}/system/tools/mkbootimg/unpack_bootimg.py"

for file in "$STOCK_RAMDISK" "$STOCK_DTB" "$RECOVERY_LZ4" "$LZ4" "$MKBOOTIMG" "$MKBOOTFS" "$AVBTOOL" "$UNPACK_BOOTIMG"; do
    if [ ! -f "$file" ]; then
        echo "missing required build input: $file" >&2
        exit 1
    fi
done
command -v python3 >/dev/null 2>&1 || {
    echo "missing required host command: python3" >&2
    exit 1
}

check_sha256() {
    local expected="$1"
    local file="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "firmware input hash mismatch: $file" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
}

check_sha256 "$STOCK_RAMDISK_SHA256" "$STOCK_RAMDISK"
check_sha256 38369239c984fc191e36d043d19ccbea4c1cd09ee6c80f8646d9493f650a30ae "$STOCK_DTB"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rodin-vendor-boot.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

recovery_cpio="${work_dir}/recovery.cpio"
platform_cpio="${work_dir}/platform.cpio"
platform_root="${work_dir}/platform-root"
platform_pruned_cpio="${work_dir}/platform-pruned.cpio"
platform_pruned_lz4="${work_dir}/platform-pruned.cpio.lz4"
disable_avb_platform_root="${work_dir}/platform-disable-avb-root"
disable_avb_platform_cpio="${work_dir}/platform-disable-avb.cpio"
disable_avb_platform_lz4="${work_dir}/platform-disable-avb.cpio.lz4"
unsigned_image="${work_dir}/vendor_boot.img"
disable_avb_unsigned_image="${work_dir}/vendor_boot-disable-avb.img"
disable_avb_bootconfig="${work_dir}/vendor_boot-disable-avb.bootconfig"
disable_avb_inspect_dir="${work_dir}/vendor_boot-disable-avb-inspect"
disable_avb_verify_image="${work_dir}/vendor_boot.img"

"$LZ4" -d -f "$RECOVERY_LZ4" "$recovery_cpio" >/dev/null
"$LZ4" -d -f "$STOCK_RAMDISK" "$platform_cpio" >/dev/null

module_count="$(cpio -it --quiet < "$recovery_cpio" | awk '/^lib\/modules\/.*\.ko$/ { count++ } END { print count + 0 }')"
if [ "$module_count" -gt 7 ]; then
    echo "recovery fragment still contains $module_count modules; expected at most 7" >&2
    exit 1
fi

# The stock platform fragment also contains a complete stock-recovery
# userspace. Normal Android boot never uses these files after /system is
# mounted, and the OrangeFox recovery fragment supplies its own copies. Drop
# only that recovery-only payload while retaining stock first-stage init,
# linker/runtime, SELinux policy, fstab, firmware, every kernel module, and
# the MediaTek AIDL BootControl binary. The recovery-specific rc file for the
# latter is replaced below so it can preload the libc++ compatibility shim.
mkdir -p "$platform_root"
(
    cd "$platform_root"
    cpio -idm --quiet --no-absolute-filenames < "$platform_cpio"
)

stock_boot_control_service="$platform_root/system/bin/hw/android.hardware.boot-service.mtk_recovery"
stock_boot_control_manifest="$platform_root/system/etc/vintf/manifest/android.hardware.boot-service.mtk.xml"
stock_boot_control_manifest_destination="$platform_root/vendor/etc/vintf/manifest/android.hardware.boot-service.mtk.xml"
for required in "$stock_boot_control_service" "$stock_boot_control_manifest" \
        "$platform_root/system/lib64/libmtk_bsg.so"; do
    if [ ! -f "$required" ]; then
        echo "stock platform ramdisk is missing required BootControl input: $required" >&2
        exit 1
    fi
done
check_sha256 7849dab766646269b3860aba028552b16c88cd52ba7b4d3f1d8a10726229c78c \
    "$stock_boot_control_service"
if ! grep -qF '<fqname>IBootControl/default</fqname>' "$stock_boot_control_manifest"; then
    echo "stock AIDL BootControl VINTF fragment is invalid" >&2
    exit 1
fi

# This is a device manifest. Keeping it below /system makes
# hwservicemanager parse it as a framework fragment, which prevents Keystore2
# from registering and leaves recovery waiting for metadata decryption.
mkdir -p "$(dirname "$stock_boot_control_manifest_destination")"
mv "$stock_boot_control_manifest" "$stock_boot_control_manifest_destination"

rm -rf "$platform_root/res"
rm -f \
    "$platform_root/miui.factoryreset.rc" \
    "$platform_root/system/bin/adbd" \
    "$platform_root/system/bin/fastbootd" \
    "$platform_root/system/bin/logcat" \
    "$platform_root/system/bin/logd" \
    "$platform_root/system/bin/recovery" \
    "$platform_root/system/bin/servicemanager" \
    "$platform_root/system/bin/sh" \
    "$platform_root/system/bin/toolbox" \
    "$platform_root/system/bin/toybox" \
    "$platform_root/system/bin/update_engine_sideload" \
    "$platform_root/system/bin/hw/android.hardware.health-service.example_recovery" \
    "$platform_root/system/etc/init/android.hardware.health-service.example_recovery.rc" \
    "$platform_root/system/etc/init/recovery-persist.rc" \
    "$platform_root/system/etc/init/recovery-refresh.rc" \
    "$platform_root/system/etc/init/servicemanager.recovery.rc" \
    "$platform_root/system/etc/recovery.fstab" \
    "$platform_root/system/etc/security/otacerts.zip" \
    "$platform_root/system/etc/init/android.hardware.boot-service.mtk_recovery.rc" \
    "$platform_root/system/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$platform_root/system/lib64/librecovery_ui.so"

if find "$platform_root/system/etc/vintf/manifest" -maxdepth 1 -type f \
        -exec grep -l 'type="device"' {} + 2>/dev/null | grep -q .; then
    echo "pruned platform still contains a device VINTF fragment under /system" >&2
    exit 1
fi

if ! grep -qF '<fqname>IBootControl/default</fqname>' "$stock_boot_control_manifest_destination"; then
    echo "relocated AIDL BootControl VINTF fragment is invalid" >&2
    exit 1
fi

for essential in \
    system/bin/init \
    system/bin/linker64 \
    system/lib64/libc.so \
    first_stage_ramdisk/fstab.mt6899 \
    lib/modules/modules.load; do
    if [ ! -f "$platform_root/$essential" ]; then
        echo "pruned platform is missing normal-boot file: $essential" >&2
        exit 1
    fi
done

platform_module_count="$(find "$platform_root/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)"
if [ "$platform_module_count" -ne 244 ]; then
    echo "pruned platform contains $platform_module_count modules; expected 244" >&2
    exit 1
fi

pack_ramdisk() {
    local root="$1" cpio="$2" lz4="$3"

    "$MKBOOTFS" -d "${PRODUCT_OUT}/system" "$root" > "$cpio"
    "$LZ4" -l -12 --favor-decSpeed -f "$cpio" "$lz4" >/dev/null
}

check_combined_ramdisk_size() {
    local label="$1" platform_lz4="$2" recovery_lz4="$3" total

    total=$(( $(stat -c %s "$platform_lz4") + $(stat -c %s "$recovery_lz4") ))
    if [ "$total" -ge 60000000 ]; then
        echo "${label} combined vendor ramdisk is $total bytes; expected less than 60000000" >&2
        exit 1
    fi
    printf '%s\n' "$total"
}

strip_first_stage_avb_flags() {
    local root="$1" fstab_file sanitized_file fstab_count=0

    while IFS= read -r -d '' fstab_file; do
        fstab_count=$((fstab_count + 1))
        sanitized_file="${fstab_file}.disable-avb"
        awk '
            /^[[:space:]]*#/ || NF < 5 { print; next }
            {
                count = split($5, options, ",")
                rebuilt = ""
                for (i = 1; i <= count; i++) {
                    option = options[i]
                    if (option == "avb" || option ~ /^avb=/ || option ~ /^avb_keys=/) {
                        continue
                    }
                    rebuilt = rebuilt == "" ? option : rebuilt "," option
                }
                $5 = rebuilt == "" ? "defaults" : rebuilt
                print
            }
        ' "$fstab_file" > "$sanitized_file"
        mv -f "$sanitized_file" "$fstab_file"
    done < <(find "$root/first_stage_ramdisk" -maxdepth 1 -type f -name 'fstab.*' -print0)

    if [ "$fstab_count" -eq 0 ]; then
        echo "no first-stage fstab files found below $root" >&2
        exit 1
    fi
}

assert_no_first_stage_avb_flags() {
    local root="$1" fstab_file fstab_count=0

    while IFS= read -r -d '' fstab_file; do
        fstab_count=$((fstab_count + 1))
        if ! awk '
            /^[[:space:]]*#/ || NF < 5 { next }
            {
                count = split($5, options, ",")
                for (i = 1; i <= count; i++) {
                    option = options[i]
                    if (option == "avb" || option ~ /^avb=/ || option ~ /^avb_keys=/) {
                        bad = 1
                    }
                }
            }
            END { exit bad ? 1 : 0 }
        ' "$fstab_file"; then
            echo "first-stage AVB flag remains in $fstab_file" >&2
            exit 1
        fi
    done < <(find "$root/first_stage_ramdisk" -maxdepth 1 -type f -name 'fstab.*' -print0)

    if [ "$fstab_count" -eq 0 ]; then
        echo "no first-stage fstab files found below $root" >&2
        exit 1
    fi
}

pack_ramdisk "$platform_root" "$platform_pruned_cpio" "$platform_pruned_lz4"

# Keep the standard image byte-for-byte independent of this override. The
# alternate image removes only fs_mgr AVB options from the stock type-1
# platform first-stage fstab. This is the fragment used for normal Android
# boot; all block paths and other mount flags stay unchanged.
mkdir -p "$disable_avb_platform_root"
cp -a "$platform_root/." "$disable_avb_platform_root/"
strip_first_stage_avb_flags "$disable_avb_platform_root"
assert_no_first_stage_avb_flags "$disable_avb_platform_root"
pack_ramdisk "$disable_avb_platform_root" "$disable_avb_platform_cpio" "$disable_avb_platform_lz4"

total_ramdisk_size="$(check_combined_ramdisk_size standard "$platform_pruned_lz4" "$RECOVERY_LZ4")"
disable_avb_total_ramdisk_size="$(check_combined_ramdisk_size disable-avb "$disable_avb_platform_lz4" "$RECOVERY_LZ4")"

build_vendor_boot() {
    local image="$1" bootconfig="$2" platform_lz4="$3" recovery_lz4="$4"
    local -a mkbootimg_args=(
        --dtb "$STOCK_DTB"
        --base 0x3fff8000
        --pagesize 4096
        --vendor_cmdline "bootopt=64S3,32N2,64N2 erofs.reserved_pages=64"
        --header_version 4
        --kernel_offset 0x00008000
        --ramdisk_offset 0x26f08000
        --tags_offset 0x07c88000
        --dtb_offset 0x07c88000
        --vendor_ramdisk "$platform_lz4"
        --ramdisk_type RECOVERY
        --ramdisk_name recovery
        --vendor_ramdisk_fragment "$recovery_lz4"
    )

    if [ -n "$bootconfig" ]; then
        mkbootimg_args+=(--vendor_bootconfig "$bootconfig")
    fi
    mkbootimg_args+=(--vendor_boot "$image")
    "$MKBOOTIMG" "${mkbootimg_args[@]}"
    "$AVBTOOL" add_hash_footer \
        --image "$image" \
        --partition_size 67108864 \
        --partition_name vendor_boot \
        --prop "com.android.build.vendor_boot.fingerprint:${fingerprint}"
}

fingerprint="$(cat "${PRODUCT_OUT}/build_fingerprint.txt")"
build_vendor_boot "$unsigned_image" "" "$platform_pruned_lz4" "$RECOVERY_LZ4"

# LK was replaced to permit fastboot flashing on affected devices, but Android
# still receives LK's locked-state boot properties. A bootconfig assignment
# with := takes precedence over the same property supplied earlier in boot.
cat > "$disable_avb_bootconfig" <<'EOF'
androidboot.vbmeta.device_state := "unlocked"
androidboot.verifiedbootstate := "orange"
androidboot.flash.locked := "0"
EOF
build_vendor_boot "$disable_avb_unsigned_image" "$disable_avb_bootconfig" \
    "$disable_avb_platform_lz4" "$RECOVERY_LZ4"

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
mv -f "$unsigned_image" "$OUTPUT_IMAGE"
sha256sum "$OUTPUT_IMAGE" > "${OUTPUT_IMAGE}.sha256"
mv -f "$disable_avb_unsigned_image" "$DISABLE_AVB_OUTPUT_IMAGE"
sha256sum "$DISABLE_AVB_OUTPUT_IMAGE" > "${DISABLE_AVB_OUTPUT_IMAGE}.sha256"

# avbtool resolves the hash descriptor's partition name relative to the image
# being checked. Validate this variant under its actual partition filename,
# rather than accidentally reading the standard product/vendor_boot.img alias.
test "$(stat -c %s "$DISABLE_AVB_OUTPUT_IMAGE")" = 67108864
cp -fp "$DISABLE_AVB_OUTPUT_IMAGE" "$disable_avb_verify_image"
"$AVBTOOL" verify_image --image "$disable_avb_verify_image"
python3 "$UNPACK_BOOTIMG" --boot_img "$DISABLE_AVB_OUTPUT_IMAGE" \
    --out "$disable_avb_inspect_dir" >/dev/null
for property in \
    'androidboot.vbmeta.device_state := "unlocked"' \
    'androidboot.verifiedbootstate := "orange"' \
    'androidboot.flash.locked := "0"'; do
    grep -qxF "$property" "$disable_avb_inspect_dir/bootconfig"
done

# OrangeFox creates these names before this post-build step. Replace both
# whole-image outputs so an ordinary vendorbootimage build cannot leave a
# recovery-only image that breaks Android boot. The installer ZIP still embeds
# the earlier recovery-only whole image, so withhold it until the installer is
# rebuilt after this system-compatible post-processing step.
cp -fp "$OUTPUT_IMAGE" "${PRODUCT_OUT}/vendor_boot.img"
cp -fp "$OUTPUT_IMAGE" "${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin.img"
md5sum "${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin.img" \
    > "${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin.img.md5"
rm -f \
    "${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin.zip" \
    "${PRODUCT_OUT}/OrangeFox-R12.0-Unofficial-rodin.zip.md5"

printf 'system-compatible vendor_boot: %s\n' "$OUTPUT_IMAGE"
printf 'disable-avb vendor_boot: %s\n' "$DISABLE_AVB_OUTPUT_IMAGE"
printf 'firmware variant: %s\n' "$FIRMWARE_VARIANT"
printf 'pruned stock platform fragment: %s bytes (LZ4, %s stock modules)\n' \
    "$(stat -c %s "$platform_pruned_lz4")" "$platform_module_count"
printf 'recovery fragment: %s bytes (LZ4, %s modules)\n' "$(stat -c %s "$RECOVERY_LZ4")" "$module_count"
printf 'combined vendor ramdisk: %s bytes\n' "$total_ramdisk_size"
printf 'disable-avb combined vendor ramdisk: %s bytes\n' "$disable_avb_total_ramdisk_size"
cat "${OUTPUT_IMAGE}.sha256"
