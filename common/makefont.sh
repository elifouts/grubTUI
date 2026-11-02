#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

if [[ -n "${GRUB_MKFONT:-}" ]]; then
  readonly FONT_TOOL="${GRUB_MKFONT}"
elif command -v grub-mkfont >/dev/null 2>&1; then
  readonly FONT_TOOL="grub-mkfont"
elif command -v grub2-mkfont >/dev/null 2>&1; then
  readonly FONT_TOOL="grub2-mkfont"
else
  printf 'error: grub-mkfont or grub2-mkfont is required\n' >&2
  exit 1
fi

generate_font() {
  local font_file="$1"
  local output_prefix="$2"
  shift 2

  for size in "$@"; do
    "${FONT_TOOL}" \
      --output "${SCRIPT_DIR}/${output_prefix}-${size}.pf2" \
      --size "${size}" \
      "${font_file}"
  done
}

usage() {
  printf 'Usage: %s [FONT_FILE OUTPUT_PREFIX [SIZE ...]]\n' "$(basename "$0")" >&2
  printf 'Without arguments, regenerate the bundled DejaVu Sans and Unifont files.\n' >&2
}

if (( $# == 0 )); then
  generate_font "${SCRIPT_DIR}/DejaVuSans.ttf" dejavu_sans 12 14 16 24 32 48
  generate_font "${SCRIPT_DIR}/unifont.otf" unifont 16 24 32
elif (( $# >= 2 )); then
  font_file="$1"
  output_prefix="$2"
  shift 2
  if (( $# == 0 )); then
    set -- 16 24 32
  fi
  generate_font "${font_file}" "${output_prefix}" "$@"
else
  usage
  exit 2
fi
