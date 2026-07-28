#!/usr/bin/env bash
set -euo pipefail

# This job runs on an ephemeral GitHub-hosted image. None of these SDKs or
# language toolchains are used by the OrangeFox build; removing them makes the
# root filesystem large enough to hold the source tree after .repo is dropped.
if ! sudo -n true; then
  echo "Passwordless sudo is required on a GitHub-hosted runner." >&2
  exit 1
fi

tool_cache="${RUNNER_TOOL_CACHE:-${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}}"
unused_paths=(
  /usr/local/lib/android
  /usr/share/dotnet
  /opt/ghc
  /usr/local/.ghcup
  /usr/local/rustup
  /usr/local/cargo
  /usr/share/swift
  /opt/google
  /opt/microsoft
  /usr/local/share/chromium
  /usr/local/share/boost
  "${tool_cache}"
)

echo "Filesystem before reclaim:"
df -h "${GITHUB_WORKSPACE:-$PWD}"

printf 'Removing unused hosted-image paths:\n'
printf '  %s\n' "${unused_paths[@]}"
sudo rm -rf -- "${unused_paths[@]}"

if command -v docker >/dev/null 2>&1; then
  sudo docker system prune --all --force --volumes || true
fi

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo "Filesystem after reclaim:"
df -h "${GITHUB_WORKSPACE:-$PWD}"
