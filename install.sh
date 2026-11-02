#!/usr/bin/env bash
# Installs one of the local themes in ./themes (gruvbox | windows).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
THEMES=()
for d in "$REPO_DIR"/themes/*/; do THEMES+=("$(basename "$d")"); done
RES="1920x1080"
ICONS=""

usage() {
  cat <<EOF
Usage: sudo $0 [-t THEME] [-c WxH] [-i ICONS] [-r THEME] [-g DIR] [-l]
       $0            (no arguments: interactive menu)

  -t, --theme THEME        install theme: ${THEMES[*]} (default: gruvbox)
  -i, --icons SET          icon set (default: keep the theme's own): ${ICON_SETS[*]}
  -u, --ui                 interactive menu
  -c, --custom-resolution  GRUB_GFXMODE to set (default $RES; windows is laid out for 1920x1080)
  -r, --remove THEME       remove an installed theme
  -s, --sync-entries       regenerate grub.cfg and re-apply the hidden boot entries list
  -T, --timeout SECONDS    seconds before the default entry boots (-1 = wait forever)
  -U, --uninstall          remove all themes and restore the original GRUB defaults
  -g, --generate DIR       only copy the theme into DIR, change nothing else
  -l, --list               list themes
  -h, --help
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo $0 ${ORIG_ARGS}"; }
valid_theme() { [[ -d "$REPO_DIR/themes/$1" ]] || die "unknown theme '$1' (available: ${THEMES[*]})"; }

if [[ -n "${GRUB_DIR:-}" ]]; then :
elif [[ -d /boot/grub2 && ! -d /boot/grub ]]; then GRUB_DIR=/boot/grub2
else GRUB_DIR=/boot/grub; fi
THEMES_DEST="$GRUB_DIR/themes"
CONF=${GRUB_DEFAULTS:-/etc/default/grub}

# Replace, uncomment or append KEY=VALUE in the grub defaults file
set_var() {
  local k=$1 v=$2
  if grep -qE "^#?[[:space:]]*${k}=" "$CONF"; then
    sed -i -E "0,/^#?[[:space:]]*${k}=.*/s||${k}=${v}|" "$CONF"
  else
    echo "${k}=${v}" >> "$CONF"
  fi
}

comment_out() { sed -i -E "s|^(${1}=.*)|#\1|" "$CONF"; }

HIDDEN_FILE=${GRUB_HIDDEN:-/etc/grub-hidden-entries}
ORDER_FILE=${GRUB_ORDER:-/etc/grub-entry-order}

# Hide entries listed in $HIDDEN_FILE and apply the order in $ORDER_FILE
filter_entries() {
  local cfg=$1
  [[ -s "$HIDDEN_FILE" || -s "$ORDER_FILE" ]] || return 0
  [[ -f "$cfg" ]] && python3 "$REPO_DIR/grub-entries.py" filter "$cfg" "$HIDDEN_FILE" "$ORDER_FILE"
}

update_grub() {
  [[ -n "${SKIP_UPDATE:-}" ]] && return
  update_grub_raw
  local cfg="$GRUB_DIR/grub.cfg"
  [[ -f /boot/efi/EFI/fedora/grub.cfg ]] && command -v grub2-mkconfig >/dev/null && cfg=/boot/efi/EFI/fedora/grub.cfg
  filter_entries "$cfg"
}

update_grub_raw() {
  if command -v update-grub >/dev/null; then update-grub
  elif command -v grub-mkconfig >/dev/null; then grub-mkconfig -o "$GRUB_DIR/grub.cfg"
  elif command -v grub2-mkconfig >/dev/null; then
    if [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
    else grub2-mkconfig -o "$GRUB_DIR/grub.cfg"; fi
  else die "no grub-mkconfig found; regenerate your grub config manually"; fi
}

icon_tier() {
  local w=${RES%%x*}
  if (( w >= 3000 )); then echo 4k; elif (( w >= 2000 )); then echo 2k; else echo 1080p; fi
}

# Replace the theme's bundled icons with the chosen variant (if one was chosen)
apply_icons() {
  [[ -n "$ICONS" ]] || return 0
  local src="$REPO_DIR/assets/assets-$ICONS/icons-$(icon_tier)"
  [[ -d "$src" ]] || die "icon set '$ICONS' not found"
  rm -rf "$1/icons"
  cp -r --no-preserve=ownership "$src" "$1/icons"
}

install_theme() {
  local theme=$1
  valid_theme "$theme"; need_root
  mkdir -p "$THEMES_DEST"
  rm -rf "${THEMES_DEST:?}/$theme"
  cp -r --no-preserve=ownership "$REPO_DIR/themes/$theme" "$THEMES_DEST/$theme"
  apply_icons "$THEMES_DEST/$theme"

  [[ -f "$CONF.bak" ]] || cp -a "$CONF" "$CONF.bak"
  set_var GRUB_THEME "\"$THEMES_DEST/$theme/theme.txt\""
  set_var GRUB_GFXMODE "$RES,auto"
  # the theme is ignored if GRUB falls back to the plain console
  comment_out GRUB_TERMINAL
  comment_out GRUB_TERMINAL_OUTPUT
  sed -i -E 's|^GRUB_BACKGROUND=|#&|' "$CONF"

  [[ $theme == windows && $RES != 1920x1080 ]] && echo "Warning: windows is laid out for 1920x1080; the menu position will be off at $RES." >&2
  update_grub
  echo "Installed '$theme'. It will show on next boot."
}

remove_theme() {
  local theme=$1; need_root
  rm -rf "${THEMES_DEST:?}/$theme"
  sed -i -E "s|^(GRUB_THEME=.*/${theme}/theme.txt.*)|#\1|" "$CONF"
  update_grub
  echo "Removed '$theme'."
}

set_timeout() {
  need_root
  [[ $1 =~ ^(-1|[0-9]+)$ ]] || die "timeout must be a number of seconds (or -1)"
  [[ -f "$CONF.bak" ]] || cp -a "$CONF" "$CONF.bak"
  set_var GRUB_TIMEOUT "$1"
  set_var GRUB_TIMEOUT_STYLE menu
  update_grub
  echo "Boot timeout set to $1."
}

uninstall_all() {
  need_root
  local t
  for t in "${THEMES[@]}"; do rm -rf "${THEMES_DEST:?}/$t"; done
  rmdir "$THEMES_DEST" 2>/dev/null || true
  if [[ -f "$CONF.bak" ]]; then
    cp -a "$CONF.bak" "$CONF" && rm -f "$CONF.bak"
  else
    sed -i -E 's|^GRUB_THEME=.*/(('"$(IFS='|'; echo "${THEMES[*]}")"'))/theme.txt.*|#&|' "$CONF"
  fi
  rm -f "$HIDDEN_FILE" "$ORDER_FILE"
  update_grub
  echo "Uninstalled. GRUB is back to its defaults."
}

ICON_SETS=()
for d in "$REPO_DIR"/assets/assets-*/; do
  n=$(basename "$d"); n=${n#assets-}
  [[ $n == select ]] || ICON_SETS+=("$n")
done

# ask TITLE DEFAULT OPTION... -> prints the chosen option (whiptail/dialog, else plain prompt)
ask() {
  local title=$1 def=$2; shift 2
  local opts=("$@")
  local ui; ui=$(command -v whiptail || command -v dialog || true)
  if [[ -n $ui ]]; then
    local items=() o
    for o in "$@"; do items+=("$o" ""); done
    "$ui" --title "GRUB themes" --default-item "$def" --menu "$title" 20 60 10 "${items[@]}" 3>&1 1>&2 2>&3 \
      || { echo "Cancelled." >&2; exit 1; }
  else
    local i reply
    {
      echo "$title"
      for i in "${!opts[@]}"; do echo "  $((i + 1))) ${opts[$i]}"; done
      read -r -p "Number [default: $def]: " reply
    } </dev/tty >/dev/tty
    if [[ -z $reply ]]; then echo "$def"
    elif [[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#opts[@]} )); then echo "${opts[$((reply - 1))]}"
    else echo "Invalid choice" >&2; exit 1; fi
  fi
}

tui() {
  local res
  theme=$(ask "Choose a theme" gruvbox "${THEMES[@]}")
  res=$(ask "Choose a resolution" "$RES" 1280x720 1366x768 1600x900 1920x1080 1920x1200 2560x1080 2560x1440 2560x1600 3440x1440 3840x2160 custom)
  if [[ $res == custom ]]; then
    read -r -p "Resolution (WxH): " res </dev/tty
    [[ $res =~ ^[0-9]+x[0-9]+$ ]] || die "invalid resolution '$res'"
  fi
  RES=$res
  ICONS=$(ask "Choose an icon set" "${ICONS:-keep}" keep "${ICON_SETS[@]}")
  [[ $ICONS == keep ]] && ICONS=""
  action=install
  # re-run as root with the choices
  if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" -t "$theme" -c "$RES" ${ICONS:+-i "$ICONS"}
  fi
}

ORIG_ARGS="$*"
action=install theme=gruvbox gen_dir=""
[[ $# -eq 0 ]] && tui
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--theme) theme=${2:?missing theme}; shift 2 ;;
    -i|--icons) ICONS=${2:?missing icon set}; shift 2 ;;
    -u|--ui) tui; shift ;;
    -c|--custom-resolution) RES=${2:?missing resolution}; shift 2 ;;
    -r|--remove) action=remove; theme=${2:?missing theme}; shift 2 ;;
    -T|--timeout) action=timeout; timeout_val=${2:?missing seconds}; shift 2 ;;
    -U|--uninstall) action=uninstall; shift ;;
    -s|--sync-entries) action=sync; shift ;;
    -g|--generate) action=generate; gen_dir=${2:?missing dir}; shift 2 ;;
    -l|--list) printf '%s\n' "${THEMES[@]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option $1" ;;
  esac
done

case $action in
  install) install_theme "$theme" ;;
  remove) remove_theme "$theme" ;;
  timeout) set_timeout "$timeout_val" ;;
  uninstall) uninstall_all ;;
  sync) need_root; update_grub; echo "Boot entries synced." ;;
  generate)
    valid_theme "$theme"; mkdir -p "$gen_dir"
    cp -r "$REPO_DIR/themes/$theme" "$gen_dir/$theme"
    echo "Generated $gen_dir/$theme" ;;
esac
