#!/bin/bash

set -euo pipefail

MODULE_DIR="${1:-$(dirname "$0")/../recovery/root/lib/modules}"
FIRMWARE_VARIANT="${RODIN_FIRMWARE_VARIANT:-cn}"
SCP="$MODULE_DIR/scp.ko"
GOODIX="$MODULE_DIR/goodix_core_rodin.ko"
FOCALTECH="$MODULE_DIR/focaltech_touch_rodin.ko"
RETURN_ZERO_HEX="00008052c0035fd6"
ENABLE_THP_HEX="09dd06b9"

SCP_STOCK_SHA256="af84b1e99602b656bb97b1268740bb773c6595caf1a9d895e76fe3e576a40c5b"
GOODIX_STOCK_SHA256="f97aaabb76d8fb3a9498ccc08593f0b479d64fbff8fb5b03ae6e4c76ca142326"
FOCALTECH_STOCK_SHA256="59e7e9fb540e14e1e9dbd5e0fe13da57ef4ca9ca9ce930ed693cc89dec3d2558"
SCP_PATCHED_SHA256="ebae9554467e148256cfbab90f0b6d7943d2818ae0cf09bad8aec650bbd99310"
GOODIX_PATCHED_SHA256="3c2fe7db061743134b715e5a7c361690c3fa36cfacb9c15c1e0bb122e51ac966"
GOODIX_NO_THP_SHA256="24128b834c42cc81d24dd6072fb6dcce1891040949c4271c614b89b11763fba0"
FOCALTECH_PATCHED_SHA256="da967ce3f94ecc81153ee91f7e06a2b48eda0526b857688016ef660844bc70b2"
GLOBAL_SCP_STOCK_SHA256="b23492d891d88afcb00637a49b19b5fa460e2ee2c297d7436dd2ada22cffcd17"
GLOBAL_GOODIX_STOCK_SHA256="c0e54ace6d081d949db7b900b0f10f890b7bf9e5eb763878f3c6874b806178d7"
GLOBAL_FOCALTECH_STOCK_SHA256="87c41bce1aa64d855b685c5105ed177fe499968d44b802b48d7bd620697fe9da"
GLOBAL_SCP_PATCHED_SHA256="f75c3dc21e7a0d7fa31b59933c42743722745389fde264de07561e44a899a385"
GLOBAL_GOODIX_PATCHED_SHA256="9a057f0b86acf69ba5530eb0ff081703263b53850307abe6ac79db4a01b80be2"
GLOBAL_FOCALTECH_PATCHED_SHA256="5806953c80ee0c88b1b4f89084ee06653bcdc57624ed97262a620690c2ae1ac4"

read_hex() {
    od -An -v -tx1 -j "$2" -N 8 "$1" | tr -d ' \n'
}

patch_return_zero() {
    local file="$1"
    local offset="$2"
    local label="$3"
    local current

    current="$(read_hex "$file" "$offset")"
    if [[ "$current" == "$RETURN_ZERO_HEX" ]]; then
        printf '%s is already patched\n' "$label"
        return
    fi

    # Every target function starts with PACIASP. Refuse unknown binaries or
    # offsets instead of writing into an unverified module.
    if [[ "${current:0:8}" != "3f2303d5" ]]; then
        printf 'unexpected bytes for %s at 0x%x: %s\n' "$label" "$offset" "$current" >&2
        exit 1
    fi

    # This script is also invoked by BOARD_RECOVERY_IMAGE_PREPARE, where
    # Android's PATH interposer rejects perl. python3 is a controlled Android
    # build tool and writes only the checked eight-byte instruction sequence.
    python3 - "$file" "$offset" "$RETURN_ZERO_HEX" <<'PY'
import sys

path, offset_text, patch_hex = sys.argv[1:]
offset = int(offset_text, 0)
patch = bytes.fromhex(patch_hex)
if len(patch) != 8:
    raise SystemExit("unexpected recovery module patch size")
with open(path, "r+b") as module:
    module.seek(offset)
    module.write(patch)
PY
    [[ "$(read_hex "$file" "$offset")" == "$RETURN_ZERO_HEX" ]]
    printf 'patched %s at 0x%x\n' "$label" "$offset"
}

restore_default_thp() {
    local file="$1"
    local offset=$((0x12e08))
    local current

    current="$(od -An -v -tx1 -j "$offset" -N 4 "$file" | tr -d ' \n')"
    if [[ "$current" == "$ENABLE_THP_HEX" ]]; then
        echo "goodix:default_thp already enables the raw-frame path"
        return
    fi
    if [[ "$current" != "1fdd06b9" ]]; then
        printf 'unexpected bytes for goodix:default_thp at 0x%x: %s\n' \
            "$offset" "$current" >&2
        exit 1
    fi

    python3 - "$file" "$offset" "$ENABLE_THP_HEX" <<'PY'
import sys

path, offset_text, patch_hex = sys.argv[1:]
offset = int(offset_text, 0)
patch = bytes.fromhex(patch_hex)
if len(patch) != 4:
    raise SystemExit("unexpected Goodix THP patch size")
with open(path, "r+b") as module:
    module.seek(offset)
    module.write(patch)
PY
    [[ "$(od -An -v -tx1 -j "$offset" -N 4 "$file" | tr -d ' \n')" == "$ENABLE_THP_HEX" ]]
    echo "restored goodix:default_thp raw-frame path at 0x12e08"
}

case "$FIRMWARE_VARIANT" in
    cn) ;;
    global)
        SCP_STOCK_SHA256="$GLOBAL_SCP_STOCK_SHA256"
        GOODIX_STOCK_SHA256="$GLOBAL_GOODIX_STOCK_SHA256"
        FOCALTECH_STOCK_SHA256="$GLOBAL_FOCALTECH_STOCK_SHA256"
        SCP_PATCHED_SHA256="$GLOBAL_SCP_PATCHED_SHA256"
        GOODIX_PATCHED_SHA256="$GLOBAL_GOODIX_PATCHED_SHA256"
        FOCALTECH_PATCHED_SHA256="$GLOBAL_FOCALTECH_PATCHED_SHA256"
        ;;
    *)
        echo "unsupported RODIN_FIRMWARE_VARIANT: $FIRMWARE_VARIANT" >&2
        exit 1
        ;;
esac

[[ -f "$SCP" && -f "$GOODIX" && -f "$FOCALTECH" ]] || {
    echo "Android 16 SCP/Goodix/FocalTech modules are missing from $MODULE_DIR" >&2
    exit 1
}

scp_sha="$(sha256sum "$SCP" | cut -d' ' -f1)"
goodix_sha="$(sha256sum "$GOODIX" | cut -d' ' -f1)"
focaltech_sha="$(sha256sum "$FOCALTECH" | cut -d' ' -f1)"

if [[ "$scp_sha" != "$SCP_STOCK_SHA256" &&
      ( -z "$SCP_PATCHED_SHA256" || "$scp_sha" != "$SCP_PATCHED_SHA256" ) ]]; then
    echo "refusing unrecognized scp.ko: $scp_sha" >&2
    exit 1
fi
if [[ "$focaltech_sha" != "$FOCALTECH_STOCK_SHA256" && \
      ( -z "$FOCALTECH_PATCHED_SHA256" || "$focaltech_sha" != "$FOCALTECH_PATCHED_SHA256" ) ]]; then
    echo "refusing unrecognized focaltech_touch_rodin.ko: $focaltech_sha" >&2
    exit 1
fi
if [[ "$goodix_sha" != "$GOODIX_STOCK_SHA256" && \
      ( -z "$GOODIX_PATCHED_SHA256" || "$goodix_sha" != "$GOODIX_PATCHED_SHA256" ) && \
      "$goodix_sha" != "$GOODIX_NO_THP_SHA256" ]]; then
    echo "refusing unrecognized goodix_core_rodin.ko: $goodix_sha" >&2
    exit 1
fi

# Recovery mode does not reserve or load the main SCP firmware. Keep the
# original module ABI and symbol CRCs, but do not register the SCP platform
# driver. Goodix still probes its AP-side SPI path; its SCP offload helpers are
# disabled because their backing memory and IPI endpoint do not exist here.
if [[ "$FIRMWARE_VARIANT" == "global" ]]; then
    # Global 6.6.89 moves .init.text by 0x178 bytes. The remaining AP-side
    # touch helper offsets are unchanged and checked by patch_return_zero.
    patch_return_zero "$SCP" $((0x20c04)) "scp:init_module"
else
    patch_return_zero "$SCP" $((0x20a8c)) "scp:init_module"
fi
patch_return_zero "$GOODIX" $((0x26e90)) "goodix:scp_tp_get_reserve_mem"
patch_return_zero "$GOODIX" $((0x26f64)) "goodix:scp_tp_ipi_send"
patch_return_zero "$GOODIX" $((0x27014)) "goodix:scp_tp_sendparam"
patch_return_zero "$GOODIX" $((0x271c0)) "goodix:scp_tp_init"
patch_return_zero "$GOODIX" $((0x27678)) "goodix:scp_tp_exit"
patch_return_zero "$GOODIX" $((0x276cc)) "goodix:scp_tp_switch"
patch_return_zero "$FOCALTECH" $((0x35b64)) "focaltech:scp_tp_get_reserve_mem"
patch_return_zero "$FOCALTECH" $((0x35c38)) "focaltech:scp_tp_ipi_send"
patch_return_zero "$FOCALTECH" $((0x35ce8)) "focaltech:scp_tp_sendparam"
patch_return_zero "$FOCALTECH" $((0x35e94)) "focaltech:scp_tp_init"
patch_return_zero "$FOCALTECH" $((0x3634c)) "focaltech:scp_tp_exit"
patch_return_zero "$FOCALTECH" $((0x363a0)) "focaltech:scp_tp_switch"

# Xiaomi's Android 16 TouchReport daemon consumes Goodix raw frames and writes
# the resulting coordinates back through /dev/xiaomi-touch. Keep THP enabled;
# the earlier standard-event experiment is not compatible with this pipeline.
restore_default_thp "$GOODIX"

[[ "$(sha256sum "$SCP" | cut -d' ' -f1)" == "$SCP_PATCHED_SHA256" ]]
[[ "$(sha256sum "$GOODIX" | cut -d' ' -f1)" == "$GOODIX_PATCHED_SHA256" ]]
[[ "$(sha256sum "$FOCALTECH" | cut -d' ' -f1)" == "$FOCALTECH_PATCHED_SHA256" ]]

echo "Recovery-only SCP/Goodix/FocalTech patch complete"
