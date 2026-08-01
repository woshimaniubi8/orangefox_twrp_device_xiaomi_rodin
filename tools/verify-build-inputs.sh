#!/usr/bin/env bash
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOP_DIR="${1:-$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)}"
failures=0

fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

case "${RODIN_FIRMWARE_VARIANT:-cn}" in
    cn|global) ;;
    *) fail "unsupported RODIN_FIRMWARE_VARIANT: ${RODIN_FIRMWARE_VARIANT} (expected cn or global)" ;;
esac

for command_name in bash cut fdtget fdtput file git grep python3 sed sha256sum sort stat strings; do
    command -v "${command_name}" >/dev/null 2>&1 || \
        fail "required host command not found: ${command_name}"
done

search_tree() {
    local marker="$1" directory="$2"

    if command -v rg >/dev/null 2>&1; then
        rg -q --fixed-strings -- "$marker" "$directory"
    else
        grep -RqsF -- "$marker" "$directory"
    fi
}

check_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

check_size() {
    local path="$1" expected="$2" actual
    check_file "$path"
    [[ -f "$path" ]] || return
    actual="$(stat -c %s "$path")"
    [[ "$actual" == "$expected" ]] || fail "unexpected size for $path: $actual (expected $expected)"
}

check_sha256() {
    local path="$1" expected="$2" actual
    check_file "$path"
    [[ -f "$path" ]] || return
    actual="$(sha256sum "$path" | cut -d' ' -f1)"
    [[ "$actual" == "$expected" ]] || fail "unexpected SHA-256 for $path: $actual"
}

check_revision() {
    local repository="$1" expected="$2" label="$3" actual

    if ! git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail "$label repository not found: $repository"
        return
    fi
    actual="$(git -C "$repository" rev-parse HEAD)"
    [[ "$actual" == "$expected" ]] || \
        fail "$label revision is $actual (expected $expected)"
}

check_contains() {
    local path="$1" marker="$2" description="$3"

    check_file "$path"
    [[ -f "$path" ]] || return
    grep -qF -- "$marker" "$path" || fail "$description: $path"
}

[[ -f "${TOP_DIR}/build/envsetup.sh" ]] || fail "not an OrangeFox source root: ${TOP_DIR}"
check_file "${DEVICE_DIR}/patches/orangefox-recovery.patch"
check_file "${DEVICE_DIR}/patches/orangefox-build-make.patch"
check_file "${DEVICE_DIR}/patches/orangefox-vendor-twrp.patch"
check_file "${DEVICE_DIR}/tools/import-global-firmware-inputs.sh"
check_file "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py"
check_file "${DEVICE_DIR}/manifests/device-blobs.sha256"
check_file "${DEVICE_DIR}/manifests/orangefox-fox_14.1-pinned.xml"
check_sha256 "${DEVICE_DIR}/patches/orangefox-build-make.patch" 5f2d3f43a4d78eee6d560a4a169df30fc95de6fa2ed294e3210e684a641a8329
check_sha256 "${DEVICE_DIR}/patches/orangefox-vendor-twrp.patch" d845e7cc38d612fa838db94da6336820b48d2e4251e109ee7b4ef2f361d22158
check_sha256 "${DEVICE_DIR}/patches/orangefox-recovery.patch" 59141a5f5f91f612caeb136c6f8626f0313dd593265d6ab49d987adc0c6390bd
check_sha256 "${DEVICE_DIR}/manifests/device-blobs.sha256" 9a0f318a8df7a99a42e8c8ebac0891626cfd5ba8eba7936e3a7ec5b22931945a

if [[ "${RODIN_ALLOW_UNPINNED_SOURCE:-0}" != "1" ]]; then
    if ! python3 "${DEVICE_DIR}/tools/verify-source-manifest.py" "${TOP_DIR}" \
            "${DEVICE_DIR}/manifests/orangefox-fox_14.1-pinned.xml"; then
        fail "OrangeFox source tree differs from the pinned manifest"
    fi
    check_revision "${TOP_DIR}/vendor/recovery" \
        0d7959e6538db5ddfff892cf7dfe207c68b0b753 "OrangeFox vendor/recovery"
    check_revision "${TOP_DIR}/external/se_omapi" \
        9ea6e4a9ecfe04ffb82767d7cbcab3e8dc6295af "OrangeFox external/se_omapi"
fi

while IFS= read -r relative; do
    [[ -n "$relative" ]] && check_file "${DEVICE_DIR}/${relative}"
done < <(sed -n 's#.*$(DEVICE_PATH)/\([^:[:space:]]*\):.*#\1#p' "${DEVICE_DIR}/device.mk" | sort -u)

check_size "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img" 67108864
check_size "${DEVICE_DIR}/prebuilt/dtbo.img" 8388608
check_size "${DEVICE_DIR}/prebuilt/dtb/mt6899-rodin.dtb" 444841
check_sha256 "${DEVICE_DIR}/prebuilt/kernel" 55caa83bf1dd1ab5e34521f1faa18532a6110a065123577a1a62d80ee5178569
check_sha256 "${DEVICE_DIR}/prebuilt/dtb/mt6899-rodin.dtb" 38369239c984fc191e36d043d19ccbea4c1cd09ee6c80f8646d9493f650a30ae
check_sha256 "${DEVICE_DIR}/prebuilt/dtbo.img" ccd008dc7336301b7cc6fab7b59400b3debd2866f055f085e61696dbc7c0f298
check_sha256 "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img" 499bb470719b790baf90f8b49a0340e09b7ed983f3508736a86a6d1e9b503f47
check_sha256 "${DEVICE_DIR}/prebuilt/vendor_ramdisk00" 192977d50a121f7a5ddfab0212488ef0dbb0326cad802ce9d664649967a9845c
check_size "${DEVICE_DIR}/prebuilt/global/vendor_ramdisk00" 29235080
check_sha256 "${DEVICE_DIR}/prebuilt/global/vendor_ramdisk00" 349cc6598f70ae401afe3071abed6de00815af39c5aded3551cff23364208731
for module in \
    focaltech_touch_rodin.ko \
    goodix_core_rodin.ko \
    nxp_i2c.ko \
    p73.ko \
    scp.ko \
    si_haptic.ko \
    xiaomi_touch_rodin.ko; do
    check_file "${DEVICE_DIR}/prebuilt/global/modules/${module}"
done
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/scp.ko" b23492d891d88afcb00637a49b19b5fa460e2ee2c297d7436dd2ada22cffcd17
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/xiaomi_touch_rodin.ko" e3532ef88d039eddf35c6d067c9d6be3161972182ffd9c0514ada6fc6291035b
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/goodix_core_rodin.ko" c0e54ace6d081d949db7b900b0f10f890b7bf9e5eb763878f3c6874b806178d7
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/focaltech_touch_rodin.ko" 87c41bce1aa64d855b685c5105ed177fe499968d44b802b48d7bd620697fe9da
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/nxp_i2c.ko" 8a8ebd267c2715d3efd9dea4da79a63dcc061ff3a0edbdd14a52d947b4b3d7be
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/p73.ko" 712cbc4503a2906ca828b1a86add1b5044c3eb892eaeb9c1bbd99450e12fb9a0
check_sha256 "${DEVICE_DIR}/prebuilt/global/modules/si_haptic.ko" e48b06dc688f5eae1b5568587376aea215b2ae9bb8310867e33df563e652c5ad
check_sha256 "${DEVICE_DIR}/recovery/root/lib/modules/scp.ko" ebae9554467e148256cfbab90f0b6d7943d2818ae0cf09bad8aec650bbd99310
check_sha256 "${DEVICE_DIR}/recovery/root/lib/modules/goodix_core_rodin.ko" 3c2fe7db061743134b715e5a7c361690c3fa36cfacb9c15c1e0bb122e51ac966
check_sha256 "${DEVICE_DIR}/recovery/root/lib/modules/focaltech_touch_rodin.ko" da967ce3f94ecc81153ee91f7e06a2b48eda0526b857688016ef660844bc70b2
check_sha256 "${DEVICE_DIR}/proprietary/odm/lib64/libtouchreport_alg_fts.so" e7cfb2b4299f0ed317225d53987b6cf9157fb4956b6ff7d42966c101faf3f1e4
check_sha256 "${DEVICE_DIR}/proprietary/fonts/MiSans.ttf" db6151d5ab2de091fbd8450df9bee1ffcde396c5a359b1030c3c58a952d81be9

# FocalTech support spans binary blobs, module metadata, product copy rules,
# init links, and the runtime readiness check. Validate every layer so a new
# source checkout cannot silently build a Goodix-only image.
check_contains "${DEVICE_DIR}/device.mk" \
    'focaltech_touch_rodin.ko:recovery/root/lib/modules/focaltech_touch_rodin.ko' \
    "FocalTech module copy rule missing"
check_contains "${DEVICE_DIR}/device.mk" \
    'libtouchreport_alg_fts.so:recovery/root/system/lib64/rodin-touch/libtouchreport_alg_fts.so' \
    "FocalTech algorithm copy rule missing"
check_contains "${DEVICE_DIR}/device.mk" \
    'rodin_fts_thp_config.ini:recovery/root/system/etc/rodin-touch/rodin_fts_thp_config.ini' \
    "FocalTech TouchReport config copy rule missing"
check_contains "${DEVICE_DIR}/recovery/root/lib/modules/modules.load.recovery" \
    'focaltech_touch_rodin.ko' "FocalTech module load entry missing"
check_contains "${DEVICE_DIR}/recovery/root/lib/modules/modules.dep" \
    '/lib/modules/focaltech_touch_rodin.ko:' "FocalTech dependency metadata missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" \
    'libtouchreport_alg_fts.so /vendor/odm/lib64/libtouchreport_alg_fts.so' \
    "FocalTech algorithm runtime link missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" \
    'rodin_fts_thp_config.ini /vendor/odm/firmware/rodin_fts_thp_config.ini' \
    "FocalTech config runtime link missing"
check_contains "${DEVICE_DIR}/recovery/root/system/bin/load-touch-modules.sh" \
    'load_module focaltech_touch_rodin.ko' "FocalTech runtime loader entry missing"
check_contains "${DEVICE_DIR}/recovery/root/system/bin/wait-touch-service.sh" \
    'goodix_ts|focaltech_ts|fts_ts)' "FocalTech input readiness names missing"
check_contains "${DEVICE_DIR}/fox_callback.sh" \
    'focaltech_touch_rodin.ko|goodix_core_rodin.ko' \
    "FocalTech module is not retained in the final ramdisk"
check_contains "${DEVICE_DIR}/fox_callback.sh" \
    'prebuilt/global/modules' \
    "Global module replacement is not configured"
check_contains "${DEVICE_DIR}/build-lowmem.sh" \
    'prepare_global_recovery_modules' \
    "Global modules are not prepared before the Make build"
check_contains "${DEVICE_DIR}/device.mk" \
    'RODIN_GLOBAL_RECOVERY_MODULE_DIR' \
    "Global module PRODUCT_COPY_FILES source is not configured"
check_contains "${DEVICE_DIR}/BoardConfig.mk" \
    'RODIN_FIRMWARE_VARIANT=$(RODIN_FIRMWARE_VARIANT)' \
    "Recovery callback does not receive the selected firmware profile"
check_contains "${DEVICE_DIR}/BoardConfig.mk" \
    'TW_DRM_BLANK_KEEP_PIPELINE := true' \
    "Global retained DRM pipeline setting is missing"
if grep -qF -- 'TW_NO_SCREEN_BLANK' "${DEVICE_DIR}/BoardConfig.mk"; then
    fail "rodin must retain the standard DRM screen-blank state machine"
fi
check_contains "${DEVICE_DIR}/tools/patch-recovery-touch-modules.sh" \
    'GLOBAL_SCP_STOCK_SHA256' \
    "Global touch patch hashes are missing"
check_contains "${DEVICE_DIR}/tools/patch-recovery-touch-modules.sh" \
    'python3 - "$file" "$offset" "$RETURN_ZERO_HEX"' \
    "Recovery module patcher does not use the Android-compatible Python tool"
if grep -qE '^[[:space:]]*perl[[:space:]]' \
        "${DEVICE_DIR}/tools/patch-recovery-touch-modules.sh"; then
    fail "Recovery module patcher uses perl, which Android PATH rejects during image assembly"
fi
check_contains "${DEVICE_DIR}/Android.bp" \
    'name: "rodin_android.hardware.secure_element-V1-ndk"' \
    "Recovery secure-element prebuilt module is missing"
check_contains "${DEVICE_DIR}/Android.bp" \
    'name: "rodin_android.se.omapi-V1-ndk"' \
    "Recovery OMAPI prebuilt module is missing"
check_contains "${DEVICE_DIR}/Android.bp" \
    '"rodin_android.se.omapi-V1-ndk"' \
    "OMAPI bridge is not linked against the recovery prebuilt"
check_contains "${DEVICE_DIR}/Android.bp" \
    '"android.hardware.secure_element-V1-ndk-source"' \
    "Secure-element AIDL generated headers are missing"
check_contains "${DEVICE_DIR}/Android.bp" \
    '"android.se.omapi-V1-ndk-source"' \
    "OMAPI AIDL generated headers are missing"
check_contains "${DEVICE_DIR}/Android.bp" \
    '"librodin_libcxx_compat"' \
    "OMAPI bridge is not linked against the libc++ compatibility shim"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'RODIN_FIRMWARE_VARIANT' \
    "firmware profile selector missing from vendor_boot repacker"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'stock_boot_control_service=' \
    "stock AIDL BootControl service is not retained by the vendor_boot repacker"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'stock_boot_control_manifest_destination="$platform_root/vendor/etc/vintf/manifest/android.hardware.boot-service.mtk.xml"' \
    "AIDL BootControl VINTF fragment is not relocated to the device manifest path"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'pruned platform still contains a device VINTF fragment under /system' \
    "vendor_boot repacker does not reject device VINTF fragments under /system"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'DEFAULT_DISABLE_AVB_OUTPUT_IMAGE' \
    "disable-avb vendor_boot output is not defined"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    '--vendor_bootconfig "$bootconfig"' \
    "disable-avb vendor_boot bootconfig is not packed"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'androidboot.vbmeta.device_state := "unlocked"' \
    "disable-avb vendor_boot does not override vbmeta device state"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'androidboot.verifiedbootstate := "orange"' \
    "disable-avb vendor_boot does not override verified boot state"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'androidboot.flash.locked := "0"' \
    "disable-avb vendor_boot does not override flash lock state"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'strip_first_stage_avb_flags' \
    "disable-avb vendor_boot does not remove first-stage AVB fs_mgr flags"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'platform first-stage fstab' \
    "disable-avb vendor_boot does not target the type-1 platform fstab"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'verify_image --image "$disable_avb_verify_image"' \
    "disable-avb vendor_boot AVB footer is not verified"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'verify_recovery_elf' \
    "vendor_boot repacker does not validate the recovery init ELF"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'patch-vendor-boot-dtb.py' \
    "vendor_boot repacker does not patch the USB offload DTB dependency"
check_contains "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py" \
    'mediatek,usb-offload' \
    "DTB patcher does not remove the xHCI USB offload dependency"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    'verify_otg_platform_stack' \
    "vendor_boot repacker does not validate the selected firmware OTG stack"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    "vbus_switch" \
    "vendor_boot repacker does not validate the Type-C VBUS control"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    "verify_global_recovery_modules" \
    "vendor_boot repacker does not reject a CN recovery fragment for Global"
check_contains "${DEVICE_DIR}/.github/workflows/build.yml" \
    'actions/cache/restore@v4' \
    "CI compiler cache is not configured"
check_contains "${DEVICE_DIR}/.github/workflows/build.yml" \
    'CCACHE_EXEC: /usr/bin/ccache' \
    "CI does not enable the host ccache executable"
check_contains "${DEVICE_DIR}/.github/workflows/build.yml" \
    'actions/cache/save@v4' \
    "CI does not save verified compiler-cache entries"
cache_best_effort_count="$(grep -cF -- 'continue-on-error: true' \
    "${DEVICE_DIR}/.github/workflows/build.yml" || true)"
[[ "${cache_best_effort_count}" -ge 2 ]] || \
    fail "CI compiler-cache restore and save must both be best-effort"
check_contains "${DEVICE_DIR}/.github/workflows/build.yml" \
    "firmware_variant:" \
    "CI cannot select a single firmware profile for manual builds"
check_contains "${DEVICE_DIR}/BoardConfig.mk" \
    'OF_USE_AIDL_BOOT_CONTROL := 1' \
    "OrangeFox is not configured to use AIDL BootControl"
check_contains "${DEVICE_DIR}/BoardConfig.mk" \
    'OF_USE_DMCTL := 1' \
    "OrangeFox dmctl support is not enabled for FBE Format Data"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/twrp.flags" \
    '/dev/block/rodin-usb-otg-unresolved' \
    "USB OTG must use the dynamic USB-bus resolver sentinel"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.bootctl.rc" \
    'service vendor.boot-default /system/bin/hw/android.hardware.boot-service.mtk_recovery' \
    "stock AIDL BootControl recovery service definition missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.bootctl.rc" \
    'setenv LD_PRELOAD /system/lib64/librodin_libcxx_compat.so' \
    "stock AIDL BootControl cannot load the libc++ compatibility shim"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" \
    'import /init.recovery.bootctl.rc' \
    "stock AIDL BootControl recovery rc is not imported"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" \
    'service rodin.omapi_bridge /system/bin/rodin_omapi_bridge' \
    "OMAPI bridge service definition missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" \
    'setenv LD_LIBRARY_PATH /vendor/lib64:/system/lib64' \
    "OMAPI bridge cannot search vendor libraries"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" \
    'start vendor.weaver_nxp' \
    "Weaver is not started with the TEE services"

if [[ -f "${DEVICE_DIR}/manifests/device-blobs.sha256" ]] && \
        ! (cd "${TOP_DIR}" && sha256sum --check --quiet "${DEVICE_DIR}/manifests/device-blobs.sha256"); then
    fail "one or more device blobs differ from manifests/device-blobs.sha256"
fi

for script in \
    "${DEVICE_DIR}/build-lowmem.sh" \
    "${DEVICE_DIR}/fox_callback.sh" \
    "${DEVICE_DIR}/tools/apply-orangefox-patches.sh" \
    "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    "${DEVICE_DIR}/tools/collect-compat-report.sh" \
    "${DEVICE_DIR}/tools/import-global-firmware-inputs.sh" \
    "${DEVICE_DIR}/tools/patch-recovery-touch-modules.sh" \
    "${DEVICE_DIR}/tools/verify-build-inputs.sh"; do
    check_file "$script"
    if [[ -f "$script" ]]; then
        bash -n "$script" || fail "shell syntax check failed: $script"
    fi
done

check_file "${DEVICE_DIR}/tools/verify-source-manifest.py"
if [[ -f "${DEVICE_DIR}/tools/verify-source-manifest.py" ]]; then
    python3 "${DEVICE_DIR}/tools/verify-source-manifest.py" --help >/dev/null || \
        fail "Python syntax check failed: tools/verify-source-manifest.py"
fi

if [[ -f "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py" ]]; then
    python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
        "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py" || \
        fail "Python syntax check failed: tools/patch-vendor-boot-dtb.py"
fi

if [[ -d "${TOP_DIR}/bootable/recovery" ]]; then
    for marker in \
        OF_SKIP_POST_DECRYPT_THEME_RELOAD \
        OF_LOAD_DEFAULT_LANGUAGE_BEFORE_DECRYPT \
        fallback_face \
        processKeyChord \
        Resolve_UsbOtg_Block_Device \
        tw_usb_otg_host_request \
        'USB OTG host mode requested by user' \
        'TARGET_OUT_SHARED_LIBRARIES)/libprocessgroup_setup.so' \
        "skipping logical partition alias" \
        "Decrypted userdata mapper is still present"; do
        search_tree "$marker" "${TOP_DIR}/bootable/recovery" || \
            fail "OrangeFox source patch marker missing: $marker"
    done
    for language in es_ES hu_HU ja_JP zh_CN zh_TW; do
        check_file "${TOP_DIR}/bootable/recovery/gui/theme/common/languages/${language}.xml"
    done

    customization="${TOP_DIR}/bootable/recovery/gui/theme/portrait_hdpi/pages/customization.xml"
    theme_fonts="${TOP_DIR}/bootable/recovery/gui/theme/portrait_hdpi/themes/font.xml"
    check_file "${customization}"
    check_file "${theme_fonts}"
    if [[ -f "${customization}" ]] && grep -Eq \
            '<listitem name="(Roboto|Roboto Slab|Google Sans|Euclid Flex|Fira Code|Exo 2|Inter Display)"' \
            "${customization}"; then
        fail "customization still exposes fonts removed from the recovery image"
    fi
    if [[ -f "${theme_fonts}" ]] && ! grep -q \
            '<variable name="theme_font" value="MiSans"/>' "${theme_fonts}"; then
        fail "OrangeFox primary theme font is not MiSans"
    fi
    if [[ -f "${theme_fonts}" ]] && ! grep -q \
            '<variable name="theme_sec_font" value="MiSans"/>' "${theme_fonts}"; then
        fail "OrangeFox secondary theme font is not MiSans"
    fi
fi

if ! grep -q '\[ -n "$input" \]' \
        "${DEVICE_DIR}/recovery/root/system/bin/wait-touch-service.sh"; then
    fail "touch readiness check is not controller-independent"
fi

if [[ -d "${TOP_DIR}/build/make" ]]; then
    for marker in \
        Fox_Before_Recovery_Image \
        orangefox_envsetup \
        BUILD_BROKEN_PLUGIN_VALIDATION; do
        search_tree "$marker" "${TOP_DIR}/build/make" || \
            fail "OrangeFox build/make patch marker missing: $marker"
    done
    if search_tree COMPRESSION_COMMANDR "${TOP_DIR}/build/make"; then
        fail "OrangeFox build/make contains misspelled COMPRESSION_COMMANDR"
    fi
fi

check_contains "${TOP_DIR}/system/vold/Android.bp" \
    '"android.hardware.weaver-V2-ndk"' \
    "OrangeFox system/vold AIDL Weaver dependency is missing"
check_contains "${TOP_DIR}/system/vold/Weaver1.cpp" \
    'AServiceManager_waitForService' \
    "OrangeFox system/vold AIDL Weaver support is missing"
check_contains "${TOP_DIR}/vendor/twrp/config/BoardConfigSoong.mk" \
    'include bootable/recovery/orangefox_soong.mk' \
    "OrangeFox vendor/twrp Soong include is missing"
check_contains "${TOP_DIR}/vendor/twrp/config/BoardConfigSoong.mk" \
    'tw_drm_blank_keep_pipeline := $(TW_DRM_BLANK_KEEP_PIPELINE)' \
    "Global retained DRM pipeline Soong export is missing"
check_contains "${TOP_DIR}/vendor/twrp/build/soong/Android.bp" \
    '-DTW_DRM_BLANK_KEEP_PIPELINE' \
    "Global retained DRM pipeline compile flag is missing"
check_contains "${TOP_DIR}/bootable/recovery/minuitwrp/graphics_drm.cpp" \
    'DRM blank request:' \
    "Atomic DRM blank diagnostics are missing"
check_contains "${TOP_DIR}/bootable/recovery/minuitwrp/graphics_drm.cpp" \
    'DRM blank retained pipeline: ACTIVE=' \
    "Global retained atomic DRM blank path is missing"
check_contains "${TOP_DIR}/bootable/recovery/minuitwrp/graphics_drm.cpp" \
    'DRM blank restore retained pipeline: framebuffer handoff' \
    "Global retained atomic DRM framebuffer-handoff wake restore is missing"
check_contains "${TOP_DIR}/bootable/recovery/minuitwrp/graphics_drm.cpp" \
    'DRM shutdown: pipeline torn down before resource release' \
    "Global DRM shutdown teardown is missing"
check_contains "${TOP_DIR}/bootable/recovery/partitions.hpp" \
    'Get_Logical_Partition_Name' \
    "logical partition name accessor is missing"
check_contains "${TOP_DIR}/bootable/recovery/partitionmanager.cpp" \
    'twrpPart->Get_Logical_Partition_Name()' \
    "logical super partition name is derived from its mount point"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab" \
    'mi_ext /mnt/vendor/mi_ext erofs ro wait,slotselect,avb=vbmeta,logical,first_stage_mount,nofail' \
    "Recovery mi_ext logical partition entry is missing"
if grep -qE '^(overlay |/mnt/vendor/mi_ext /mi_ext )' \
        "${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab"; then
    fail "Recovery fstab must not contain Android init-only mi_ext bind or overlay entries"
fi
check_contains "${TOP_DIR}/bootable/recovery/data.cpp" \
    'Persist is mounted read-only; skipping OrangeFox settings write' \
    "read-only persist write guard is missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" \
    'mount none /mnt/vendor/persist /persist bind' \
    "Recovery persist bind alias is missing"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/twrp.flags" \
    'flags=display="persist";fsflags=ro,noload' \
    "Recovery persist must remain read-only and journal-safe"

if command -v file >/dev/null 2>&1 && [[ -f "${DEVICE_DIR}/proprietary/fonts/MiSans.ttf" ]]; then
    file "${DEVICE_DIR}/proprietary/fonts/MiSans.ttf" | grep -q 'TrueType Font data' || \
        fail "MiSans must use TrueType glyf outlines, not CFF"
fi

if (( failures > 0 )); then
    echo "Preflight failed with ${failures} error(s)" >&2
    exit 1
fi

echo "rodin build input verification passed"
echo "OrangeFox top: ${TOP_DIR}"
echo "Device tree:   ${DEVICE_DIR}"
