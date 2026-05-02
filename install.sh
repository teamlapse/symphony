#!/bin/sh
set -eu

REPO="${SYMPHONY_REPO:-teamlapse/symphony}"
ASSET="symphony-darwin-arm64.tar.gz"
BIN_NAME="symphony"

die() {
  printf '%s\n' "symphony install: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

download() {
  url="$1"
  output="$2"

  if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    curl -fsSL -H "Authorization: Bearer ${token}" "$url" -o "$output"
  else
    curl -fsSL "$url" -o "$output"
  fi
}

need curl
need tar
need shasum
need awk

[ "$(uname -s)" = "Darwin" ] || die "only macOS is supported by this installer"
[ "$(uname -m)" = "arm64" ] || die "only Apple Silicon macOS is supported"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

release_url="https://github.com/${REPO}/releases/latest/download"
download "${release_url}/${ASSET}" "${tmp_dir}/${ASSET}"
download "${release_url}/checksums.sha256" "${tmp_dir}/checksums.sha256"

expected="$(
  awk -v asset="$ASSET" '$2 == asset { print $1 }' "${tmp_dir}/checksums.sha256"
)"
[ -n "$expected" ] || die "checksum file did not contain ${ASSET}"

actual="$(shasum -a 256 "${tmp_dir}/${ASSET}" | awk '{ print $1 }')"
[ "$actual" = "$expected" ] || die "checksum mismatch for ${ASSET}"

tar -xzf "${tmp_dir}/${ASSET}" -C "$tmp_dir"
[ -f "${tmp_dir}/${BIN_NAME}" ] || die "archive did not contain ${BIN_NAME}"
chmod +x "${tmp_dir}/${BIN_NAME}"

if command -v "$BIN_NAME" >/dev/null 2>&1; then
  install_path="$(command -v "$BIN_NAME")"
  install_dir="$(dirname "$install_path")"
else
  install_dir="${SYMPHONY_INSTALL_DIR:-$HOME/.local/bin}"
  install_path="${install_dir}/${BIN_NAME}"
fi

if [ -w "$install_dir" ] || { [ ! -e "$install_dir" ] && mkdir -p "$install_dir" 2>/dev/null; }; then
  mkdir -p "$install_dir"
  cp "${tmp_dir}/${BIN_NAME}" "$install_path"
  chmod 755 "$install_path"
else
  command -v sudo >/dev/null 2>&1 || die "${install_dir} is not writable and sudo is unavailable"
  sudo mkdir -p "$install_dir"
  sudo cp "${tmp_dir}/${BIN_NAME}" "$install_path"
  sudo chmod 755 "$install_path"
fi

printf 'Installed %s to %s\n' "$BIN_NAME" "$install_path"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) printf 'Add %s to PATH to run %s directly.\n' "$install_dir" "$BIN_NAME" ;;
esac
