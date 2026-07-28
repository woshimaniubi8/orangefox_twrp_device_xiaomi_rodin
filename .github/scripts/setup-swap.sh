#!/usr/bin/env bash
set -euo pipefail

SWAPFILE="${SWAPFILE:-/swapfile-orangefox}"
SWAPSIZE="${SWAPSIZE:-16G}"
MIN_SWAP_GIB="${MIN_SWAP_GIB:-12}"

if ! [[ "${MIN_SWAP_GIB}" =~ ^[1-9][0-9]*$ ]]; then
  echo "MIN_SWAP_GIB must be a positive integer: ${MIN_SWAP_GIB}" >&2
  exit 1
fi

if ! [[ "${SWAPSIZE}" =~ ^[1-9][0-9]*G$ ]]; then
  echo "SWAPSIZE must use whole GiB units, for example 16G: ${SWAPSIZE}" >&2
  exit 1
fi

required_swap_kib=$((MIN_SWAP_GIB * 1024 * 1024))
current_swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"

if (( current_swap_kib >= required_swap_kib )); then
  echo "Existing swap satisfies the ${MIN_SWAP_GIB} GiB requirement."
  free -h
  exit 0
fi

if ! sudo -n true; then
  echo "Passwordless sudo is required to create build swap." >&2
  exit 1
fi

if sudo swapon --show=NAME --noheadings | awk '{$1=$1; print}' | grep -Fxq "$SWAPFILE"; then
  echo "${SWAPFILE} is already active but total swap is below ${MIN_SWAP_GIB} GiB." >&2
  exit 1
fi

if [[ -e "${SWAPFILE}" ]]; then
  sudo rm -f "${SWAPFILE}"
fi

echo "Creating ${SWAPSIZE} swap at ${SWAPFILE}"
if ! sudo fallocate -l "${SWAPSIZE}" "${SWAPFILE}"; then
  swap_mib=$(( ${SWAPSIZE%G} * 1024 ))
  sudo dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${swap_mib}" status=progress
fi

sudo chmod 600 "${SWAPFILE}"
sudo mkswap "${SWAPFILE}" >/dev/null
if ! sudo swapon "${SWAPFILE}"; then
  sudo rm -f "${SWAPFILE}"
  echo "Unable to enable ${SWAPFILE}. Preconfigure swap on an ext4 or xfs runner filesystem." >&2
  exit 1
fi

current_swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
if (( current_swap_kib < required_swap_kib )); then
  echo "Swap setup did not reach the ${MIN_SWAP_GIB} GiB requirement." >&2
  exit 1
fi

free -h
