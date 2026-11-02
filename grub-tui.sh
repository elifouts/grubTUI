#!/usr/bin/env bash
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$REPO_DIR/install.sh"
CUSTOM_PY="$REPO_DIR/grub-custom.py"
if [[ -n "${GRUB_DIR:-}" ]]; then :
elif [[ -d /boot/grub2 && ! -d /boot/grub ]]; then GRUB_DIR=/boot/grub2
else GRUB_DIR=/boot/grub; fi
CONF=${GRUB_DEFAULTS:-/etc/default/grub}
[[ -t 0 && -t 1 ]] || { echo "grub-tui needs an interactive terminal" >&2; exit 1; }

SUDO=""; [[ $EUID -eq 0 ]] || SUDO="sudo"
if [[ -n $SUDO ]]; then command -v sudo >/dev/null || { echo "sudo required" >&2; exit 1; }; sudo -v || exit 1; fi

if ! python3 -c 'import PIL' 2>/dev/null; then
  echo "Pillow (python imaging) is missing; it is needed to build themes."
  read -r -p "Install it now? [Y/n] " ans
  if [[ ! $ans =~ ^[Nn] ]]; then
    if command -v pacman >/dev/null; then $SUDO pacman -S --needed --noconfirm python-pillow
    elif command -v apt-get >/dev/null; then $SUDO apt-get install -y python3-pil
    elif command -v dnf >/dev/null; then $SUDO dnf install -y python3-pillow
    else echo "Install Pillow manually: pip install pillow"; fi
  fi
fi

R=$'\e[0m' B=$'\e[1m' D=$'\e[2m'
ACC=$'\e[36m' OK=$'\e[32m' WARN=$'\e[33m' ERR=$'\e[31m' MUT=$'\e[2m'
SELBG=$'\e[7m'

THEMES=(); for d in "$REPO_DIR"/themes/*/; do THEMES+=("$(basename "$d")"); done
ICON_SETS=(keep); for d in "$REPO_DIR"/assets/assets-*/; do n=$(basename "$d"); n=${n#assets-}; [[ $n == select ]] || ICON_SETS+=("$n"); done

cleanup() { printf '\e[?25h\e[?1049l'; stty echo 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT TERM
printf '\e[?1049h\e[?25l'

at() { printf '\e[%d;%dH' "$1" "$2"; }
rep() { local s; ((${2:-0} > 0)) || return 0; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

vlen() {
  local s=$1
  while [[ $s =~ $'\e'\[[0-9\;]*m ]]; do s=${s//"${BASH_REMATCH[0]}"/}; done
  VL=${#s}
}

box() {
  local r=$1 c=$2 w=$3 h=$4 t=$5 col=${6:-$ACC} i
  at "$r" "$c"; printf '%s╭─ %s%s%s %s╮%s' "$col" "$B" "$t" "$R$col" "$(rep ─ $((w - ${#t} - 5)))" "$R"
  for ((i = 1; i < h - 1; i++)); do at $((r + i)) "$c"; printf '%s│%*s│%s' "$col" $((w - 2)) '' "$R"; done
  at $((r + h - 1)) "$c"; printf '%s╰%s╯%s' "$col" "$(rep ─ $((w - 2)))" "$R"
}

installed_list() { local t; for t in "${THEMES[@]}"; do $SUDO test -f "$GRUB_DIR/themes/$t/theme.txt" && echo "$t"; done; }
active_theme() { sed -nE 's|^GRUB_THEME="?.*/([^/]+)/theme.txt.*|\1|p' "$CONF" 2>/dev/null | head -1; }

COLS=80 ROWS=24 OFF=0 UW=80
size() {
  read -r ROWS COLS < <(stty size)
  UW=$COLS; ((UW > 100)) && UW=100
  OFF=$(((COLS - UW) / 2))
}

ctr() { at "$1" $(((COLS - ${#2}) / 2 + 1)); printf '%s%s%s' "${3:-}" "$2" "$R"; }
ctrl() { at "$1" 1; printf '\e[2K'; ctr "$@"; }

LOGO_ROWS=5
CRUMB="Main menu"

sub() { local saved=$CRUMB; CRUMB="$CRUMB  ›  $1"; shift; "$@"; CRUMB=$saved; }
frame() {
  size; printf '\e[?2026h\e[H'; [[ -z ${KEEP:-} ]] && printf '\e[2J'
  local logo=(
    '  ___ ___ _   _ ___   _____ _  _ ___ __  __ ___ ___ '
    ' / __| _ \ | | | _ ) |_   _| || | __|  \/  | __/ __|'
    '| (_ | / | |_| | _ \   | | | __ | _|| |\/| | _|\__ \'
    ' \___|_|_\\___/|___/   |_| |_||_|___|_|  |_|___|___/')
  local i; for i in 0 1 2 3; do ctr $((i + 2)) "${logo[$i]}" "$ACC$B"; done
  ctr 6 "$CRUMB" "$MUT"
  ctrl "$ROWS" "$1" "$MUT"
}
flush() { printf '\e[?2026l'; }

menu() {
  local title=$1 note=$2; shift 2
  local items=("$@") n=$# sel=-1 prev k rest i w=0 top left label num
  local -a labels descs heads nums
  for ((i = 0; i < n; i++)); do
    label=${items[$i]%%::*}; descs[i]=""; [[ ${items[$i]} == *::* ]] && descs[i]=${items[$i]#*::}
    if [[ $label == "##"* ]]; then heads[i]=1; label=${label#\#\#}; else heads[i]=0; fi
    labels[i]=$label
    vlen "$label"; ((VL + 12 > w)) && w=$((VL + 12))
  done
  for ((i = 0; i < n; i++)); do ((heads[i] == 0)) && { sel=$i; break; }; done
  ((sel < 0)) && return 1
  ((w < ${#title} + 8)) && w=$((${#title} + 8)); ((w < 46)) && w=46
  num=0; for ((i = 0; i < n; i++)); do if ((heads[i] == 0)); then num=$((num + 1)); nums[i]=$num; else nums[i]=0; fi; done

  draw_row() {
    local i=$1 lead="  " vl pad
    at $((top + 2 + i)) $((left + 2))
    if ((heads[i])); then printf ' %s── %s ──%s' "$MUT$B" "${labels[i]}" "$R"; return; fi
    [[ -n ${NUMBERED:-} && ${nums[i]} -le 9 ]] && lead="${nums[i]} "
    vlen "${labels[i]}"; pad=$(rep ' ' $((w - 11 - VL)))
    if (($2)); then printf '%s ▸ %s%s%s%s' "$SELBG" "$lead" "${labels[i]//$'\e[0m'/$R$SELBG}" "$pad" "$R"
    else printf '   %s%s%s' "$lead" "${labels[i]}" "$pad"; fi
  }
  draw_hint() { ctrl $((top + n + 5)) "${descs[sel]}" "$WARN"; }

  KEEP="" frame "↑↓ move · Enter or → select · ← or q back${NUMBERED:+ · 1-9 jump}"
  [[ -n $note ]] && ctrl $((ROWS - 1)) "$note" "$MUT"
  left=$(((COLS - w) / 2 + 1))
  top=$((LOGO_ROWS + 3 + (ROWS - LOGO_ROWS - 3 - n - 6) / 2)); ((top < LOGO_ROWS + 3)) && top=$((LOGO_ROWS + 3))
  box "$top" "$left" "$w" $((n + 4)) "$title"
  for ((i = 0; i < n; i++)); do draw_row "$i" $((i == sel)); done
  draw_hint; flush

  while true; do
    IFS= read -rsn1 k || return 1
    [[ $k == $'\e' ]] && { read -rsn2 -t 0.02 rest || true; k+=${rest:-}; }
    prev=$sel
    case $k in
      $'\e[A'|k) for ((i = sel - 1; i >= 0; i--)); do ((heads[i] == 0)) && { sel=$i; break; }; done ;;
      $'\e[B'|j) for ((i = sel + 1; i < n; i++)); do ((heads[i] == 0)) && { sel=$i; break; }; done ;;
      [1-9])
        if [[ -n ${NUMBERED:-} ]]; then
          for ((i = 0; i < n; i++)); do
            if ((nums[i] == k)); then CHOICE=$i; CHOSEN=${labels[i]}; return 0; fi
          done
        fi ;;
      ''|$'\n'|$'\e[C'|l) CHOICE=$sel; CHOSEN=${labels[sel]}; return 0 ;;
      q|Q|$'\e'|$'\e[D'|h|b) return 1 ;;
    esac
    if ((sel != prev)); then
      printf '\e[?2026h'; draw_row "$prev" 0; draw_row "$sel" 1; draw_hint; flush
    fi
  done
}

run_action() {
  printf '\e[H\e[2J\e[?25h'
  printf '%s%s%s\n\n' "$ACC$B" "▌ $1" "$R"; shift
  "$@"; local rc=$?
  echo
  if ((rc == 0)); then printf '%s✔ Done%s' "$OK" "$R"; else printf '%s✘ Failed (exit %d)%s' "$ERR" "$rc" "$R"; fi
  printf '  %s— press any key%s' "$MUT" "$R"
  printf '\e[?25l'; read -rsn1 _
}

screen_install() {
  local items=() name kind
  while IFS=$'\t' read -r name kind; do
    items+=("$name::Theme")
  done < <(python3 "$CUSTOM_PY" list)
  menu "Choose a theme" "" "${items[@]}" || return
  local theme=$CHOSEN
  local resl=(1280x720 1366x768 1600x900 1920x1080 1920x1200 2560x1080 2560x1440 2560x1600 3440x1440 3840x2160 custom)
  menu "Resolution for $theme" "" "${resl[@]}" || return
  local res=${resl[$CHOICE]}
  if [[ $res == custom ]]; then
    printf '\e[H\e[2J\e[?25h'; read -r -p "Resolution (WxH): " res
    [[ $res =~ ^[0-9]+x[0-9]+$ ]] || { printf '\e[?25l'; return; }
    printf '\e[?25l'
  fi
  menu "Icon set" "" "${ICON_SETS[@]}" || return
  local icons=${ICON_SETS[$CHOICE]} args=(-t "$theme" -c "$res")
  [[ $icons != keep ]] && args+=(-i "$icons")
  run_action "Installing $theme @ $res" $SUDO "$INSTALL" "${args[@]}"
}

HIDDEN_FILE=${GRUB_HIDDEN:-/etc/grub-hidden-entries}
ORDER_FILE=${GRUB_ORDER:-/etc/grub-entry-order}
ENTRIES_PY="$REPO_DIR/grub-entries.py"

screen_entries() {
  local pane=1 s0=0 s1=0 off0=0 off1=0 k rest i w x top vis p cnt sel off name label status="" want="" kind depth title
  local -a h_t s_t s_d
  local reload=1 KEEP=""
  while true; do
    if ((reload)); then
      reload=0; KEEP=""
      h_t=(); s_t=(); s_d=()
      while IFS=$'\t' read -r kind depth title; do
        if [[ $kind == shown ]]; then s_t+=("$title"); s_d+=("$depth"); else h_t+=("$title"); fi
      done < <($SUDO python3 "$ENTRIES_PY" list "$GRUB_DIR/grub.cfg" "$HIDDEN_FILE" "$ORDER_FILE" 2>/dev/null)
      if [[ -n $want ]]; then
        for i in "${!s_t[@]}"; do [[ ${s_d[$i]} == 0 && ${s_t[$i]} == "$want" ]] && s1=$i; done; want=""
      fi
    fi
    ((s0 >= ${#h_t[@]})) && s0=$((${#h_t[@]} > 0 ? ${#h_t[@]} - 1 : 0))
    ((s1 >= ${#s_t[@]})) && s1=$((${#s_t[@]} > 0 ? ${#s_t[@]} - 1 : 0))
    frame "Tab/←→ switch · ↑↓ move · Enter hide/show · K/J reorder · q back"
    w=$(((UW - 6) / 2)); x=$((OFF + 2)); top=$((LOGO_ROWS + 3))
    vis=$((ROWS - top - 6)); ((vis < 3)) && vis=3
    cnt=${#s_t[@]}; ((${#h_t[@]} > cnt)) && cnt=${#h_t[@]}; ((cnt > vis)) && cnt=$vis; ((cnt < 3)) && cnt=3
    ((s0 < off0)) && off0=$s0; ((s0 >= off0 + vis)) && off0=$((s0 - vis + 1))
    ((s1 < off1)) && off1=$s1; ((s1 >= off1 + vis)) && off1=$((s1 - vis + 1))
    box "$top" "$x" "$w" $((cnt + 4)) "Hidden (still detected)" "$MUT"
    box "$top" $((x + w + 2)) "$w" $((cnt + 4)) "Boot menu (top → bottom)" "$OK"
    for p in 0 1; do
      if ((p == 0)); then total=${#h_t[@]}; sel=$s0; off=$off0; else total=${#s_t[@]}; sel=$s1; off=$off1; fi
      for ((i = 0; i < cnt && off + i < total; i++)); do
        if ((p == 0)); then label=${h_t[$((off + i))]}
        else
          local idx=$((off + i)) nd=0
          ((idx + 1 < total)) && nd=${s_d[$((idx + 1))]}
          if ((${s_d[$idx]} == 0)); then
            if ((nd == 1)); then label="▾ ${s_t[$idx]}"; else label="  ${s_t[$idx]}"; fi
          elif ((nd == 1)); then label="  ├─ ${s_t[$idx]}"
          else label="  └─ ${s_t[$idx]}"; fi
        fi
        label=${label:0:$((w - 6))}
        at $((top + 2 + i)) $((x + 2 + p * (w + 2)))
        if ((pane == p && sel == off + i)); then printf '%s %-*s%s' "$SELBG" $((w - 6)) "$label" "$R"
        else printf ' %-*s' $((w - 6)) "$label"; fi
      done
      ((total == 0)) && { at $((top + 2)) $((x + 2 + p * (w + 2))); printf '%s (none)%s' "$MUT" "$R"; }
      ((total > cnt)) && { at $((top + cnt + 3)) $((x + 3 + p * (w + 2))); printf '%s%-9s%s' "$MUT" "$((sel + 1))/$total" "$R"; }
    done
    ctrl $((top + cnt + 5)) "$status" "$WARN"; status=""
    flush; KEEP=1
    IFS= read -rsn1 k || return
    if [[ $k == $'\e' ]]; then
      read -rsn2 -t 0.02 rest || true; k+=${rest:-}
      if [[ $k == $'\e[1' ]]; then read -rsn3 -t 0.02 rest || true
        case ${rest:-} in ";2A") k=K ;; ";2B") k=J ;; esac; fi
    fi
    case $k in
      $'\e[A'|k) if ((pane == 0)); then ((s0 > 0)) && s0=$((s0 - 1)); else ((s1 > 0)) && s1=$((s1 - 1)); fi ;;
      $'\e[B'|j) if ((pane == 0)); then ((s0 < ${#h_t[@]} - 1)) && s0=$((s0 + 1)); else ((s1 < ${#s_t[@]} - 1)) && s1=$((s1 + 1)); fi ;;
      $'\t'|$'\e[C'|$'\e[D'|h|l) pane=$((1 - pane)) ;;
      K|J)
        if ((pane == 1 && ${#s_t[@]} > 0)); then
          if ((${s_d[$s1]} != 0)); then status="Only top-level entries can be reordered"
          else
            at $((top + cnt + 5)) 1; ctr $((top + cnt + 5)) "Reordering…" "$WARN"
            title=${s_t[$s1]}; want=$title
            $SUDO python3 "$ENTRIES_PY" move "$GRUB_DIR/grub.cfg" "$HIDDEN_FILE" "$ORDER_FILE" "$([[ $k == K ]] && echo up || echo down)" "$title" \
              && $SUDO "$INSTALL" -s >/dev/null 2>&1 || status="Reorder failed"
            reload=1
          fi
        fi ;;
      ''|$'\n')
        if ((pane == 1 && ${#s_t[@]} > 0)); then
          title=${s_t[$s1]}
          run_action "Hiding: $title" bash -c '
            printf "%s\n" "$1" | '"$SUDO"' tee -a "$2" >/dev/null && '"$SUDO"' "$3" -s' _ "$title" "$HIDDEN_FILE" "$INSTALL"
          reload=1
        elif ((pane == 0 && ${#h_t[@]} > 0)); then
          title=${h_t[$s0]}
          local tmp; tmp=$(mktemp); grep -vxF -- "$title" "$HIDDEN_FILE" > "$tmp"
          run_action "Showing: $title" bash -c "$SUDO"' cp "$1" "$2" && '"$SUDO"' "$3" -s' _ "$tmp" "$HIDDEN_FILE" "$INSTALL"
          rm -f "$tmp"; reload=1
        fi ;;
      q|Q|$'\e') return ;;
    esac
  done
}

screen_uninstall() {
  menu "Restore default GRUB? (removes all themes)" "" "No, go back" "Yes, uninstall everything" || return
  ((CHOICE == 1)) && run_action "Uninstalling" $SUDO "$INSTALL" -U
}

cfg_get() { python3 "$CUSTOM_PY" get "$1" 2>/dev/null; }

ask_text() {
  printf '\e[H\e[2J\e[?25h'
  printf '%s%s%s\n\n' "$ACC$B" "▌ $1" "$R"
  read -e -r -i "$2" -p "  > " REPLY
  printf '\e[?25l'
}

custom_set() {
  local out
  out=$(python3 "$CUSTOM_PY" set "$1" "$2" 2>&1) || { run_action "Invalid value" bash -c 'echo "$1"; exit 1' _ "$out"; }
}

build_and_apply() {
  local n
  n=$($SUDO python3 "$ENTRIES_PY" list "$GRUB_DIR/grub.cfg" "$HIDDEN_FILE" "$ORDER_FILE" 2>/dev/null | awk -F'\t' '$1=="shown" && $2==0' | wc -l)
  GRUB_ENTRY_COUNT=$n python3 "$CUSTOM_PY" build && $SUDO "$INSTALL" -t "$(cfg_get name)" -c "$(cfg_get resolution)"
}

radius_slider() {
  local r=$1 k rest i line KEEP=""
  while true; do
    frame "←/→ change by 2 · ↑/↓ by 10 · Enter confirm · q cancel"
    ctrl 9 "Corner radius: $r px" "$B"
    local filled=$((r * 40 / 80)) bar=""
    for ((i = 0; i < 40; i++)); do ((i < filled)) && bar+="█" || bar+="░"; done
    ctr 11 "0 $bar 80" "$ACC"
    local c=$((r * 6 / 80)); ((c > 6)) && c=6
    local top="╭" bot="╰"
    for ((i = 0; i < 20; i++)); do top+="─"; bot+="─"; done
    if ((c == 0)); then top="┌${top:1}┐"; bot="└${bot:1}┘"; line="│                    │"; else top+="╮"; bot+="╯"; line="│                    │"; fi
    ctr 14 "$top" "$ACC"; ctr 15 "$line" "$ACC"; ctr 16 "$bot" "$ACC"
    ctr 18 "(preview is approximate; the real card is drawn in pixels)" "$MUT"
    flush; KEEP=1
    IFS= read -rsn1 k || return 1
    [[ $k == $'\e' ]] && { read -rsn2 -t 0.02 rest || true; k+=${rest:-}; }
    case $k in
      $'\e[C'|l) ((r < 80)) && r=$((r + 2)) ;;
      $'\e[D'|h) ((r > 0)) && r=$((r - 2)) ;;
      $'\e[A'|k) ((r <= 70)) && r=$((r + 10)) || r=80 ;;
      $'\e[B'|j) ((r >= 10)) && r=$((r - 10)) || r=0 ;;
      ''|$'\n') RADIUS=$r; return 0 ;;
      q|Q|$'\e') return 1 ;;
    esac
  done
}

PRESETS=("#ffffff White" "#000000 Black" "#0a78d7 Windows blue" "#2f95f0 Sky" "#83a598 Gruvbox aqua" "#b8bb26 Gruvbox green" "#fabd2f Gruvbox yellow" "#fb4934 Red" "#d3869b Pink" "#cba6f7 Lavender" "#a6e3a1 Mint" "#f9e2af Cream" "#101820 Midnight" "#282828 Charcoal")

swatch() {
  local h=${1#\#}
  printf '\e[48;2;%d;%d;%dm  \e[0m' $((16#${h:0:2})) $((16#${h:2:2})) $((16#${h:4:2}))
}

pick_color() {
  local label=$1 key=$2 cur items=() p
  cur=$(cfg_get "$key")
  for p in "${PRESETS[@]}"; do items+=("$(swatch "${p%% *}") ${p%% *}  ${p#* }"); done
  items+=("Type a hex value…")
  menu "$label (now $cur)" "" "${items[@]}" || return
  if ((CHOICE < ${#PRESETS[@]})); then custom_set "$key" "${PRESETS[$CHOICE]%% *}"
  else ask_text "$label (#rrggbb)" "$cur"; [[ -n $REPLY ]] && custom_set "$key" "$REPLY"; fi
}

pick_number() {
  local label=$1 key=$2; shift 2
  local vals=("$@")
  menu "$label (now $(cfg_get "$key"))" "" "${vals[@]}" "Type a number…" || return
  if ((CHOICE < ${#vals[@]})); then custom_set "$key" "${vals[$CHOICE]}"
  else ask_text "$label" "$(cfg_get "$key")"; [[ -n $REPLY ]] && custom_set "$key" "$REPLY"; fi
}

screen_appearance() {
  local sw labels keys i
  sw() { printf '%s' "$(swatch "$(cfg_get "$1")") $(cfg_get "$1")"; }
  while true; do
    labels=("Menu text color        $(sw text)" "Selected text color    $(sw selected_text)" "Selector color         $(sw highlight)" "Selector style         $(cfg_get highlight_style)" "Info tabs color        $(sw info_color)" "Countdown text color   $(sw timeout_color)" "Countdown message      $(cfg_get timeout_text)")
    keys=(text selected_text highlight highlight_style info_color timeout_color timeout_text)
    labels+=("Menu background style $(cfg_get card_style)" "Menu background color $(sw card_color)")
    keys+=(card_style card_color)
    labels+=("Corner radius          $(cfg_get radius) px")
    keys+=(radius)
    local wpl; wpl=$(cfg_get wallpaper); wpl=${wpl:-<unchanged>}; ((${#wpl} > 30)) && wpl="…${wpl: -29}"
    labels+=("Background image       $wpl")
    keys+=(wallpaper)
    local font_family; font_family=$(cfg_get font_family)
    local font_label="JetBrains Nerd"
    [[ $font_family == terminus ]] && font_label="Terminus (16)"
    [[ $font_family == keep ]] && font_label="Keep current"
    labels+=("Font                  $font_label")
    keys+=(font_family)
    [[ $font_family == nerd ]] && { labels+=("Font size              $(cfg_get font_size)"); keys+=(font_size); }
    labels+=("Icon size              $(cfg_get icon_size)" "Item spacing           $(cfg_get item_spacing)")
    keys+=(icon_size item_spacing)
    menu "Appearance" "" "${labels[@]}" || return
    case ${keys[$CHOICE]} in
      text) pick_color "Menu text color" text ;;
      selected_text) pick_color "Selected text color" selected_text ;;
      highlight) pick_color "Selector (highlight) color" highlight ;;
      highlight_style) menu "Selector style" "full = solid · blurry = translucent glass · invisible = outline only" full blurry invisible || continue
         custom_set highlight_style "$(printf '%s\n' full blurry invisible | sed -n "$((CHOICE + 1))p")" ;;
      info_color) pick_color "Info tabs color" info_color ;;
      timeout_color) pick_color "Countdown text color" timeout_color ;;
      timeout_text) ask_text "Countdown message (keep %d for the seconds)" "$(cfg_get timeout_text)"; [[ -n $REPLY ]] && custom_set timeout_text "$REPLY" ;;
      card_style) menu "Menu background style" "blurry = frosted glass · full = solid · invisible = no background" blurry full invisible || continue
         custom_set card_style "$(printf '%s\n' blurry full invisible | sed -n "$((CHOICE + 1))p")" ;;
      card_color) pick_color "Menu background color" card_color ;;
      wallpaper) ask_text "Path to background image (png/jpg/webp/…)" "$(cfg_get wallpaper)"; [[ -n $REPLY ]] && custom_set wallpaper "$REPLY" ;;
      radius) radius_slider "$(cfg_get radius)" && custom_set radius "$RADIUS" ;;
      font_family)
        if [[ -n ${STYLE_ONLY:-} ]]; then
          menu "Font family" "Keep current or choose a bundled font" \
            "Keep current" "JetBrains Mono Nerd Font" "Terminus Regular 16" || continue
          case $CHOICE in 0) custom_set font_family keep ;; 1) custom_set font_family nerd ;; 2) custom_set font_family terminus ;; esac
        else
          menu "Font family" "Terminus uses its bundled 16px font; JetBrains Nerd supports font sizing" \
            "JetBrains Mono Nerd Font" "Terminus Regular 16" || continue
          if [[ $CHOICE == 0 ]]; then custom_set font_family nerd; else custom_set font_family terminus; fi
        fi ;;
      font_size) pick_number "Font size" font_size 18 20 22 24 26 28 30 32 36 ;;
      icon_size) pick_number "Icon size" icon_size 24 32 48 64 ;;
      item_spacing) pick_number "Item spacing" item_spacing 0 5 10 15 20 ;;
    esac
  done
}

screen_custom() {
  local wp res nm
  local resl=(1280x720 1366x768 1600x900 1920x1080 1920x1200 2560x1080 2560x1440 2560x1600 3440x1440 3840x2160 custom)
  while true; do
    nm=$(cfg_get name); wp=$(cfg_get wallpaper); res=$(cfg_get resolution)
    local wl=${wp:-<not set>}; ((${#wl} > 36)) && wl="…${wl: -35}"
    menu "Create a theme" "" \
      "Name:       $nm" \
      "Wallpaper:  $wl" \
      "Resolution: $res" \
      "Appearance (colors, card, fonts, …)" \
      "Layout editor (drag & resize)" \
      "Build & apply theme '$nm'" || return
    case $CHOICE in
      0) ask_text "Theme name (letters, digits, - _)" "$nm"; [[ -n $REPLY ]] && custom_set name "$REPLY" ;;
      1) ask_text "Path to wallpaper (png/jpg/webp/bmp/gif/tiff…)" "$wp"; [[ -n $REPLY ]] && custom_set wallpaper "$REPLY" ;;
      2) menu "Resolution" "" "${resl[@]}" || continue
         if [[ ${resl[$CHOICE]} == custom ]]; then ask_text "Resolution (WxH)" "$res"; custom_set resolution "$REPLY"
         else custom_set resolution "${resl[$CHOICE]}"; fi ;;
      3) sub "Appearance" screen_appearance ;;
      4) python3 "$CUSTOM_PY" layout; printf '\e[?25l' ;;
      5) run_action "Building theme $nm" build_and_apply ;;
    esac
  done
}

screen_timeout() {
  local cur opts=(3 5 10 15 30 60) labels=()
  cur=$(sed -nE 's/^GRUB_TIMEOUT=//p' "$CONF" 2>/dev/null | head -1)
  local o; for o in "${opts[@]}"; do labels+=("$o seconds"); done
  labels+=("Wait forever (never auto-boot)" "Custom…")
  menu "Boot timeout (now: ${cur:-unset})" "" "${labels[@]}" || return
  local val
  if ((CHOICE < ${#opts[@]})); then val=${opts[$CHOICE]}
  elif ((CHOICE == ${#opts[@]})); then val=-1
  else ask_text "Seconds before the default entry boots" "${cur:-5}"; val=$REPLY; fi
  [[ -n $val ]] && run_action "Setting boot timeout to $val" $SUDO "$INSTALL" -T "$val"
}

screen_edit_layout() {
  local items=() name kind res=$TMPDIR_UI/result
  while IFS=$'\t' read -r name kind; do
    case $kind in
      *) items+=("$name::Changes are saved into it and applied") ;;
    esac
  done < <(python3 "$CUSTOM_PY" list)
  menu "Edit the layout of…" "Drag the boot menu, info tabs and countdown anywhere" "${items[@]}" || return
  local theme=$CHOSEN
  if [[ $(python3 "$CUSTOM_PY" list | awk -F'\t' -v t="$theme" '$1==t {print $2}') == builder ]]; then
    local GRUB_CUSTOM_CFG=$TMPDIR_UI/style.json; export GRUB_CUSTOM_CFG
    if python3 "$CUSTOM_PY" style-load "$theme"; then
      python3 "$CUSTOM_PY" layout; printf '\e[?25l'
      run_action "Rebuilding $theme" build_and_apply
    fi
    unset GRUB_CUSTOM_CFG; return
  fi
  rm -f "$res"
  python3 "$CUSTOM_PY" edit "$theme" "$res"; printf '\e[?25l'
  if [[ -s $res ]]; then
    local saved; saved=$(<"$res")
    run_action "Applying $saved" $SUDO "$INSTALL" -t "$saved" -c 1920x1080
  fi
}

theme_installed() { $SUDO test -f "$GRUB_DIR/themes/$1/theme.txt"; }

delete_theme_action() {
  theme_installed "$1" && { $SUDO "$INSTALL" -r "$1" || return 1; }
  python3 "$CUSTOM_PY" delete "$1"
}

restyle_and_install() {
  python3 "$CUSTOM_PY" restyle "$1" && $SUDO "$INSTALL" -t "$1" -c 1920x1080
}

edit_appearance() {
  local name=$1 kind=$2 out
  if [[ $kind == bundled ]]; then
    python3 "$CUSTOM_PY" adopt "$name" || return
    kind=variant
  fi
  local GRUB_CUSTOM_CFG=$TMPDIR_UI/style.json
  export GRUB_CUSTOM_CFG
  if ! out=$(python3 "$CUSTOM_PY" style-load "$name" 2>&1); then
    run_action "Cannot edit $name" bash -c 'echo "$1"; exit 1' _ "$out"
    unset GRUB_CUSTOM_CFG; return
  fi
  local STYLE_ONLY=""; [[ $kind == variant ]] && STYLE_ONLY=1
  sub "Appearance of $name" screen_appearance
  if menu "Apply the changes to '$name'?" "" "Apply::Rebuild the theme and make it active" "Discard changes"; then
    if [[ $CHOSEN == Apply* ]]; then
      if [[ $kind == variant ]]; then run_action "Updating $name" restyle_and_install "$name"
      else run_action "Rebuilding $name" build_and_apply; fi
    fi
  fi
  unset GRUB_CUSTOM_CFG
}

screen_my_themes() {
  local items name kind act sub
  local -A kinds
  while true; do
    items=(); act=$(active_theme)
    while IFS=$'\t' read -r name kind; do
      kinds[$name]=$kind
      local st="not installed"
      theme_installed "$name" && st="installed"
      [[ $name == "$act" ]] && st="ACTIVE in GRUB"
      items+=("$name::$st")
    done < <(python3 "$CUSTOM_PY" list)
    if ((${#items[@]} == 0)); then
      run_action "My themes" bash -c 'echo "You have no themes yet."; echo; echo "Create one from \"Create a theme from your wallpaper\" or \"Edit the layout of a theme\"."'
      return
    fi
    menu "My themes" "Select a theme to apply or delete it" "${items[@]}" || return
    name=$CHOSEN
    if [[ ${kinds[$name]} == bundled ]]; then
      menu "$name" "" "Apply in GRUB::Install it and make it the active theme" "Edit appearance::Colors, background, highlight" "Back" || continue
    else
      menu "$name" "" "Apply in GRUB::Install it and make it the active theme" "Edit appearance::Colors, highlight, countdown$([[ ${kinds[$name]} == builder ]] && echo ', card, fonts, spacing')" "Delete::Remove it from GRUB and from this folder" "Back" || continue
    fi
    case $CHOSEN in
      Edit*) edit_appearance "$name" "${kinds[$name]}" ;;
      Apply*) run_action "Applying $name" $SUDO "$INSTALL" -t "$name" -c "$(python3 "$CUSTOM_PY" get resolution)" ;;
      Delete*)
        local warn=""; [[ $name == "$act" ]] && warn="  (active: GRUB will go back to no theme)"
        menu "Delete '$name'?$warn" "This cannot be undone" "No, keep it" "Yes, delete it" || continue
        [[ $CHOSEN == Yes* ]] && run_action "Deleting $name" delete_theme_action "$name" ;;
    esac
  done
}

TMPDIR_UI=$(mktemp -d)
trap 'rm -rf "$TMPDIR_UI"; cleanup' EXIT

while true; do
  THEMES=(); for d in "$REPO_DIR"/themes/*/; do THEMES+=("$(basename "$d")"); done
  inst=$(installed_list | paste -sd, -); act=$(active_theme)
  NUMBERED=1 menu "Main menu" "installed: ${inst:-none} · active: ${act:-none}" \
    "##Themes" \
    "Install a theme::Pick a theme and put it in GRUB" \
    "Create a theme from a wallpaper::Your own image, colors, rounded cards and layout" \
    "Edit the layout of a theme::Drag the menu around; saved into the theme and applied" \
    "My themes::Apply, restyle or delete your themes" \
    "##Boot menu" \
    "Boot entries::Hide, show and reorder Windows, Arch, ..." \
    "Boot timeout::How long GRUB waits before booting the default" \
    "##Other" \
    "Uninstall (restore default GRUB)::Remove every theme and go back to plain GRUB" \
    "Quit" || break
  case $CHOSEN in
    Install*) sub "Install a theme" screen_install ;;
    Create*) sub "Create a theme" screen_custom ;;
    Edit*) sub "Edit layout" screen_edit_layout ;;
    My*) sub "My themes" screen_my_themes ;;
    "Boot entries"*) sub "Boot entries" screen_entries ;;
    "Boot timeout"*) sub "Boot timeout" screen_timeout ;;
    Uninstall*) sub "Uninstall" screen_uninstall ;;
    Quit*) break ;;
  esac
done
