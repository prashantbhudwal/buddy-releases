#!/usr/bin/env bash
set -euo pipefail

REPO="${BUDDY_RELEASE_REPO:-prashantbhudwal/buddy-releases}"
DEST_DIR="${BUDDY_DOWNLOAD_DIR:-$HOME/Downloads/buddy-release}"
QUARANTINE_ATTR="com.apple.quarantine"
BUDDY_APP_PATH="/Applications/Buddy.app"
LATEST_RELEASE_DOWNLOAD_BASE_URL="https://github.com/${REPO}/releases/latest/download"
DOWNLOAD_RETRIES="${BUDDY_DOWNLOAD_RETRIES:-3}"

case "$(uname -m)" in
  arm64)
    ARCH="arm64"
    ARCH_LABEL="apple-silicon"
    ;;
  x86_64)
    ARCH="x64"
    ARCH_LABEL="intel"
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${DEST_DIR}"

case "${DOWNLOAD_RETRIES}" in
  "" | *[!0-9]* | 0)
    echo "BUDDY_DOWNLOAD_RETRIES must be a positive integer, got: ${DOWNLOAD_RETRIES}" >&2
    exit 1
    ;;
esac

ASSET_NAME=""
ASSET_URL=""
TAG="latest"

resolve_latest_release_tag() {
  local api_url="https://api.github.com/repos/${REPO}/releases/latest"
  local tag

  tag="$(
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${api_url}" |
      sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' |
      head -1
  )"

  if [[ -z "${tag}" ]]; then
    echo "Could not resolve latest Buddy release tag from ${api_url}" >&2
    exit 1
  fi

  TAG="${tag}"
}

version_from_tag() {
  printf '%s\n' "${TAG#v}"
}

download_candidate_asset() {
  local candidate_name="$1"
  local candidate_url="${LATEST_RELEASE_DOWNLOAD_BASE_URL}/${candidate_name}"
  local candidate_output="${DEST_DIR}/${candidate_name}"
  local attempt=1
  local delay_seconds=2

  echo "Downloading ${candidate_name} from latest release..."
  while (( attempt <= DOWNLOAD_RETRIES )); do
    if curl -fL --connect-timeout 20 --progress-bar "${candidate_url}" -o "${candidate_output}"; then
      ASSET_NAME="${candidate_name}"
      ASSET_URL="${candidate_url}"
      OUTPUT_PATH="${candidate_output}"
      return 0
    fi

    rm -f "${candidate_output}"
    if (( attempt == DOWNLOAD_RETRIES )); then
      return 1
    fi

    echo "Download attempt ${attempt}/${DOWNLOAD_RETRIES} failed. Retrying in ${delay_seconds}s..."
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
    delay_seconds=$((delay_seconds * 2))
  done

  return 1
}

resolve_release_tag_from_asset_url() {
  local asset_url="$1"
  local final_url
  local resolved_tag

  final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${asset_url}" || true)"
  resolved_tag="$(printf '%s\n' "${final_url}" | sed -nE 's|.*/releases/download/([^/]+)/.*|\1|p')"

  if [[ -n "${resolved_tag}" ]]; then
    TAG="${resolved_tag}"
  fi
}

resolve_latest_release_tag

VERSION="$(version_from_tag)"
CURRENT_ASSET_BASENAME="buddy-v${VERSION}-macos-${ARCH_LABEL}"
LEGACY_ASSET_BASENAME="buddy-electron-mac-${ARCH}"
CANDIDATE_ASSETS=(
  "${CURRENT_ASSET_BASENAME}.dmg"
  "${CURRENT_ASSET_BASENAME}.zip"
  "${LEGACY_ASSET_BASENAME}.dmg"
  "${LEGACY_ASSET_BASENAME}.zip"
)

if download_candidate_asset "${CANDIDATE_ASSETS[0]}"; then
  :
elif download_candidate_asset "${CANDIDATE_ASSETS[1]}"; then
  :
elif download_candidate_asset "${CANDIDATE_ASSETS[2]}"; then
  :
elif download_candidate_asset "${CANDIDATE_ASSETS[3]}"; then
  :
else
  echo "Latest release ${TAG} does not contain a supported macOS asset for ${ARCH}" >&2
  exit 1
fi

resolve_release_tag_from_asset_url "${ASSET_URL}"

echo "Removing quarantine flag from ${ASSET_NAME}..."
/usr/bin/xattr -d "${QUARANTINE_ATTR}" "${OUTPUT_PATH}" 2>/dev/null || true

echo "Saved to ${OUTPUT_PATH}"
echo "Opening ${OUTPUT_PATH}..."
/usr/bin/open "${OUTPUT_PATH}"

cat <<EOF

Opened the latest Buddy release package.

Removed ${QUARANTINE_ATTR} from the downloaded package.
If macOS still blocks Buddy after install, run:
  xattr -rd ${QUARANTINE_ATTR} "${BUDDY_APP_PATH}"
Release: ${TAG}
Asset: ${ASSET_NAME}
Path: ${OUTPUT_PATH}
EOF
