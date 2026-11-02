#!/usr/bin/env python3
"""GRUB theme builder with a mouse-driven layout editor.

  grub-custom.py get KEY            print one setting
  grub-custom.py show               print all settings
  grub-custom.py resolutions        list common resolutions (any WxH is accepted)
  grub-custom.py set KEY VALUE      change a setting: name, wallpaper, resolution, font_size, text, selected_text,
                                    highlight, highlight_style, info_color, timeout_color, timeout_text,
                                    card_style (blurry|full|invisible), card_color, radius, item_spacing,
                                    icon_size, entries
  grub-custom.py layout             drag/resize the boot menu, info bar and countdown label
  grub-custom.py list               list themes (name<TAB>bundled|variant|builder)
  grub-custom.py edit THEME RESULT  edit a theme's layout; saves as THEME-mineN, writes its name to RESULT
  grub-custom.py delete NAME        delete one of your themes (never bundled ones)
  grub-custom.py preview [THEME]    render previews/<theme>.png (all themes if omitted)
  grub-custom.py build              convert the wallpaper and generate themes/<name>
"""
import copy
import curses
import glob
import json
import os
import re
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:
    sys.exit("Pillow is required: pacman -S python-pillow | apt install python3-pil | dnf install python3-pillow | pip install pillow")

REPO = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get("GRUB_CUSTOM_CFG") or os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "grub-theme-tui", "working.json")
BASE = os.path.join(REPO, "assets", "builder-base")
NERD_TTF = [
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFontPropo-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMonoNerdFontPropo-Regular.ttf",
]
MARKER = "theme.json"
INFO_RATIO = 42 / 480
BASE_RES = (1920, 1080)
RESOLUTIONS = ["1280x720", "1366x768", "1600x900", "1920x1080", "1920x1200", "2560x1080", "2560x1440", "2560x1600", "3440x1440", "3840x2160"]

DEFAULTS = {
    "name": "custom",
    "wallpaper": "",
    "resolution": "1920x1080",
    "font_size": 26,
    "text": "#ffffff",
    "selected_text": "#0a78d7",
    "highlight": "#ffffff",
    "highlight_style": "full",
    "info_color": "#ffffff",
    "timeout_color": "#ffffff",
    "timeout_text": "Booting in %d seconds",
    "item_spacing": 16,
    "icon_size": 32,
    "card_style": "blurry",
    "card_color": "#101820",
    "radius": 16,
    "entries": "auto",
    # x, y, width, height in pixels at `resolution`
    "layout": {
        "menu": [470, 190, 700, 300],
        "info": [720, 1030, 480, 42],
        "timeout": [614, 886, 691, 34],
    },
}


def parse_res(res):
    m = re.fullmatch(r"(\d+)x(\d+)", res)
    if not m:
        sys.exit(f"invalid resolution '{res}' (want WxH)")
    return int(m.group(1)), int(m.group(2))


def load():
    cfg = copy.deepcopy(DEFAULTS)
    try:
        saved = json.load(open(CFG))
    except (FileNotFoundError, ValueError):
        saved = {}
    layout = saved.pop("layout", {})
    cfg.update(saved)
    cfg["layout"].update(layout)
    return cfg


def save(cfg):
    os.makedirs(os.path.dirname(CFG), exist_ok=True)
    with open(CFG, "w") as f:
        json.dump(cfg, f, indent=2)


def rescale(cfg, new_res):
    ow, oh = parse_res(cfg["resolution"])
    nw, nh = parse_res(new_res)
    for name, (x, y, w, h) in cfg["layout"].items():
        cfg["layout"][name] = [round(x * nw / ow), round(y * nh / oh), round(w * nw / ow), round(h * nh / oh)]
    cfg["resolution"] = new_res


def check_color(value):
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        sys.exit(f"invalid color '{value}' (want #rrggbb)")
    return value.lower()


# ---------------------------------------------------------------- layout editor

NAMES = ["menu", "info", "timeout"]
LABELS = {"menu": "BOOT MENU", "info": "INFO BAR", "timeout": "COUNTDOWN"}
SAMPLE = ["Arch Linux", "Advanced options for Arch", "Windows Boot Manager", "Reboot to firmware settings"]


def editor(stdscr, cfg, save_fn=None):
    save_fn = save_fn or save
    names = [n for n in NAMES if n in cfg["layout"]]
    W, H = parse_res(cfg["resolution"])
    lay = cfg["layout"]
    curses.curs_set(0)
    curses.use_default_colors()
    for i, col in enumerate((33, 71, 173), 1):
        curses.init_pair(i, curses.COLOR_BLACK, col)
        curses.init_pair(i + 3, col, -1)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    stdscr.keypad(True)
    sys.stdout.write("\x1b[?1003h")  # report motion so drags are seen
    sys.stdout.flush()

    sel, drag, dirty, status, quit_armed = 0, None, False, "", False
    saved_once = False

    def geometry():
        rows, cols = stdscr.getmaxyx()
        cw = max(20, min(cols - 2, int(2 * (rows - 8) * W / H)))
        ch = max(6, int(cw * H / W / 2))
        return rows, cols, cw, ch, (cols - cw) // 2, 2, W / cw, H / ch

    def cells(name, g):
        x, y, w, h = lay[name]
        _, _, cw, ch, _, _, sx, sy = g
        x0, y0 = round(x / sx), round(y / sy)
        x1 = max(x0 + 4, round((x + w) / sx))
        y1 = max(y0 + 1, round((y + h) / sy))
        return x0, y0, min(x1, cw), min(y1, ch)

    def clamp(name):
        x, y, w, h = lay[name]
        w = max(60, min(w, W))
        h = max(20, min(h, H))
        if name == "info":
            h = round(w * INFO_RATIO)
        lay[name] = [max(0, min(x, W - w)), max(0, min(y, H - h)), w, h]

    def put(r, c, text, attr=0):
        try:
            stdscr.addstr(r, c, text, attr)
        except curses.error:
            pass

    def draw():
        g = geometry()
        rows, cols, cw, ch, ox, oy, sx, sy = g
        stdscr.erase()
        put(0, 1, f"GRUB layout editor  {W}x{H}", curses.A_BOLD)
        put(oy - 1, ox, "┌" + "─" * (cw - 2) + "┐")
        for r in range(ch):
            put(oy + r, ox, "│" + " " * (cw - 2) + "│")
        put(oy + ch, ox, "└" + "─" * (cw - 2) + "┘")
        order = [n for i, n in enumerate(names) if i != sel] + [names[sel]]
        for name in order:
            x0, y0, x1, y1 = cells(name, g)
            i = names.index(name)
            attr = curses.color_pair(i + 1) | (curses.A_BOLD if i == sel else 0)
            for r in range(y0, y1):
                put(oy + r, ox + x0, " " * (x1 - x0), attr)
            title = LABELS[name] + (" ◢" if i == sel else "")
            put(oy + y0, ox + x0 + 1, title[: x1 - x0 - 2], attr | curses.A_BOLD)
            if name == "menu":
                for k, line in enumerate(SAMPLE[: max(0, y1 - y0 - 1)]):
                    put(oy + y0 + 1 + k, ox + x0 + 1, (("▸ " if k == 0 else "  ") + line)[: x1 - x0 - 2], attr)
            put(oy + y1 - 1, ox + x1 - 1, "◢", attr)
        x, y, w, h = lay[names[sel]]
        put(oy + ch + 1, 1, f"{LABELS[names[sel]]}: x={x} y={y} w={w} h={h}" + ("   [unsaved]" if dirty else ""), curses.A_BOLD)
        put(oy + ch + 2, 1, "mouse: drag to move · drag ◢ corner to resize")
        put(oy + ch + 3, 1, "keys: Tab select · arrows move · +/- width · [ ] height · c center · s save · q quit")
        if status:
            put(oy + ch + 4, 1, status, curses.color_pair(3 + 1))
        stdscr.refresh()
        return g

    try:
        while True:
            g = draw()
            _, _, cw, ch, ox, oy, sx, sy = g
            key = stdscr.getch()
            name = names[sel]
            status = ""
            x, y, w, h = lay[name]
            if key == curses.KEY_MOUSE:
                try:
                    _, mx, my, _, bs = curses.getmouse()
                except curses.error:
                    continue
                cx, cy = mx - ox, my - oy
                if bs & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                    quit_armed = False
                    hit = None
                    for n in [names[sel]] + [n for i, n in enumerate(names) if i != sel]:
                        x0, y0, x1, y1 = cells(n, g)
                        if x0 <= cx < x1 and y0 <= cy < y1:
                            hit = n
                            break
                    if hit:
                        sel = names.index(hit)
                        x0, y0, x1, y1 = cells(hit, g)
                        if cx >= x1 - 2 and cy >= y1 - 1:
                            drag = ("resize", 0, 0)
                        else:
                            drag = ("move", cx - x0, cy - y0)
                elif bs & curses.BUTTON1_RELEASED:
                    drag = None
                elif drag:
                    if drag[0] == "move":
                        lay[name][0] = round((cx - drag[1]) * sx)
                        lay[name][1] = round((cy - drag[2]) * sy)
                    else:
                        lay[name][2] = round((cx + 1) * sx) - x
                        if name == "menu":
                            lay[name][3] = round((cy + 1) * sy) - y
                    clamp(name)
                    dirty = True
                continue
            quit_armed_prev, quit_armed = quit_armed, False
            step = max(1, round(sx))
            if key in (9, ord(" "), curses.KEY_BTAB):
                sel = (sel + 1) % len(names)
            elif key == curses.KEY_LEFT:
                lay[name][0] -= step
            elif key == curses.KEY_RIGHT:
                lay[name][0] += step
            elif key == curses.KEY_UP:
                lay[name][1] -= round(sy)
            elif key == curses.KEY_DOWN:
                lay[name][1] += round(sy)
            elif key in (ord("+"), ord("=")):
                lay[name][2] += 2 * step
            elif key in (ord("-"), ord("_")):
                lay[name][2] -= 2 * step
            elif key == ord("]") and name == "menu":
                lay[name][3] += round(sy)
            elif key == ord("[") and name == "menu":
                lay[name][3] -= round(sy)
            elif key == ord("c"):
                lay[name][0] = (W - w) // 2
            elif key == ord("s"):
                save_fn(cfg)
                dirty = False
                saved_once = True
                status = "saved"
                continue
            elif key in (ord("q"), 27):
                if dirty and not quit_armed_prev:
                    quit_armed = True
                    status = "unsaved changes: press q again to discard, or s to save"
                    continue
                return saved_once
            else:
                continue
            clamp(name)
            dirty = True
    finally:
        sys.stdout.write("\x1b[?1003l")
        sys.stdout.flush()


# ---------------------------------------------------------------- builder


def find_nerd_ttf():
    for path in NERD_TTF:
        if os.path.exists(path):
            return path
    hits = glob.glob("/usr/share/fonts/**/JetBrainsMonoNerdFontPropo-Regular.ttf", recursive=True)
    return hits[0] if hits else None


def ensure_font(size):
    """Put jbnerd-<size>.pf2 in the theme; fall back to the nearest bundled size."""
    dest = os.path.join(OUT, f"jbnerd-{size}.pf2")
    bundled = os.path.join(BASE, f"jbnerd-{size}.pf2")
    if os.path.exists(bundled):
        shutil.copy(bundled, dest)
        return size
    ttf, mk = find_nerd_ttf(), shutil.which("grub-mkfont") or shutil.which("grub2-mkfont")
    if ttf and mk:
        subprocess.run([mk, "-s", str(size), "-n", "JB Nerd", "-o", dest, ttf], stderr=subprocess.DEVNULL, check=True)
        return size
    sizes = sorted(int(re.search(r"(\d+)\.pf2", p).group(1)) for p in glob.glob(os.path.join(BASE, "jbnerd-*.pf2")))
    best = min(sizes, key=lambda s: abs(s - size))
    print(f"note: cannot build font size {size} (need grub-mkfont + JetBrainsMono Nerd Font); using {best}", file=sys.stderr)
    shutil.copy(os.path.join(BASE, f"jbnerd-{best}.pf2"), os.path.join(OUT, f"jbnerd-{best}.pf2"))
    return best


def hex_rgb(value):
    return tuple(int(value[i:i + 2], 16) for i in (1, 3, 5))


def theme_dir(cfg):
    return os.path.join(REPO, "themes", cfg["name"])


def check_name(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", name):
        sys.exit("theme name: letters, digits, - and _ only (max 32, must start with a letter or digit)")
    if name in ("gruvbox", "windows"):
        sys.exit(f"'{name}' is a bundled theme; pick another name")
    return name


def rounded_mask(w, h, r):
    ss = 4
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], radius=r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def prepare_wallpaper(src, W, H):
    """Any Pillow-readable image -> RGB, scaled to cover W x H and center-cropped."""
    img = Image.open(src)
    try:
        from PIL import ImageOps
        img = ImageOps.exif_transpose(img)
    except Exception:
        pass
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        flat = Image.new("RGB", img.size, (0, 0, 0))
        flat.paste(img.convert("RGBA"), mask=img.convert("RGBA").getchannel("A"))
        img = flat
    else:
        img = img.convert("RGB")
    scale = max(W / img.width, H / img.height)
    img = img.resize((max(W, round(img.width * scale)), max(H, round(img.height * scale))), Image.LANCZOS)
    left, top = (img.width - W) // 2, (img.height - H) // 2
    return img.crop((left, top, left + W, top + H))


def draw_card(img, rect, style, radius, color):
    """Bake the card behind the boot list into the wallpaper."""
    if style == "invisible":
        return
    W, H = img.size
    x, y, w, h = rect
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    w, h = x1 - x0, y1 - y0
    if w < 2 or h < 2:
        return
    radius = max(0, min(radius, w // 2, h // 2))
    solid = Image.new("RGB", (w, h), hex_rgb(color))
    if style == "blurry":
        m = 80
        bx0, by0, bx1, by1 = max(0, x0 - m), max(0, y0 - m), min(W, x1 + m), min(H, y1 + m)
        blurred = img.crop((bx0, by0, bx1, by1)).filter(ImageFilter.GaussianBlur(24))
        region = blurred.crop((x0 - bx0, y0 - by0, x1 - bx0, y1 - by0))
        card = Image.blend(region, solid, 0.45)
    else:
        card = solid
    img.paste(card, (x0, y0), rounded_mask(w, h, radius))


def write_highlight(out, color, radius, style="full", prefix="select"):
    """Nine-slice select_*.png with rounded corners. style: full (solid), blurry (translucent glass), invisible (outline only)."""
    r = max(3 if style != "full" else 1, radius)
    size = 2 * r + 2
    mask = rounded_mask(size, size, radius) if radius > 0 else Image.new("L", (size, size), 255)
    rgb = hex_rgb(color)
    if style == "full":
        alpha = mask
    else:
        inner = Image.new("L", (size, size), 0)
        inner.paste(rounded_mask(size - 4, size - 4, max(0, radius - 2)) if radius > 2 else Image.new("L", (size - 4, size - 4), 255), (2, 2))
        ring = ImageChops.subtract(mask, inner)
        if style == "invisible":
            alpha = ring
        else:
            fill = mask.point(lambda v: v * 110 // 255)
            alpha = ImageChops.lighter(fill, ring.point(lambda v: v * 230 // 255))
    base = Image.new("RGBA", (size, size), rgb + (255,))
    base.putalpha(alpha)
    pieces = {
        "nw": (0, 0, r, r), "n": (r, 0, r + 1, r), "ne": (size - r, 0, size, r),
        "w": (0, r, r, r + 1), "c": (r, r, r + 1, r + 1), "e": (size - r, r, size, r + 1),
        "sw": (0, size - r, r, size), "s": (r, size - r, r + 1, size), "se": (size - r, size - r, size, size),
    }
    for name, box in pieces.items():
        base.crop(box).save(os.path.join(out, f"{prefix}_{name}.png"))


NINE = ("nw", "n", "ne", "w", "c", "e", "sw", "s", "se")


def write_item_pads(out):
    """Invisible item_*.png with the same sizes as select_*.png. GRUB offsets a selected item's text by the
    selector's border size, so unselected items need an equally large (transparent) border or the text jumps."""
    for n in NINE:
        sel = os.path.join(out, f"select_{n}.png")
        if os.path.isfile(sel):
            Image.new("RGBA", Image.open(sel).size, (0, 0, 0, 0)).save(os.path.join(out, f"item_{n}.png"))


def write_menu_box(out, color, radius, style):
    """Translucent or solid rounded panel behind the boot menu (GRUB's menu_pixmap_style); invisible removes it."""
    for n in NINE:
        try:
            os.remove(os.path.join(out, f"menu_{n}.png"))
        except OSError:
            pass
    if style == "invisible":
        return
    r = max(1, min(radius, 12))
    size = 2 * r + 2
    mask = rounded_mask(size, size, r)
    alpha = mask if style == "full" else mask.point(lambda v: v * 150 // 255)
    base = Image.new("RGBA", (size, size), hex_rgb(color) + (255,))
    base.putalpha(alpha)
    boxes = {"nw": (0, 0, r, r), "n": (r, 0, r + 1, r), "ne": (size - r, 0, size, r),
             "w": (0, r, r, r + 1), "c": (r, r, r + 1, r + 1), "e": (size - r, r, size, r + 1),
             "sw": (0, size - r, r, size), "s": (r, size - r, r + 1, size), "se": (size - r, size - r, size, size)}
    for n, box in boxes.items():
        base.crop(box).save(os.path.join(out, f"menu_{n}.png"))


def entry_count(cfg):
    value = cfg.get("entries", "auto")
    if str(value).isdigit() and int(value) > 0:
        return int(value)
    env = os.environ.get("GRUB_ENTRY_COUNT", "")
    if env.isdigit() and int(env) > 0:
        return int(env)
    for path in ("/boot/grub/grub.cfg", "/boot/grub2/grub.cfg"):
        try:
            n = sum(1 for line in open(path) if re.match(r"(menuentry|submenu)\s", line))
        except OSError:
            continue
        if n:
            return n
    return 4


def build(cfg):
    src = os.path.expanduser(cfg["wallpaper"])
    if not src or not os.path.isfile(src):
        sys.exit("wallpaper not set or file not found: set it first")
    name = check_name(cfg["name"])
    out = theme_dir(cfg)
    W, H = parse_res(cfg["resolution"])
    try:
        img = prepare_wallpaper(src, W, H)
    except Exception as e:
        sys.exit(f"cannot read wallpaper: {e}")

    size = int(cfg["font_size"])
    radius = int(cfg["radius"])
    spacing, pad = int(cfg["item_spacing"]), 20
    icon = int(cfg["icon_size"])
    # GRUB grows the selector by its corner size on every side, so the text box is kept tight
    # and the corner (pad) small enough that the selector never touches the next entry
    pad_sel = max(3 if cfg["highlight_style"] != "full" else 1, min(radius, 10, spacing))
    item_h = max(size, icon) + 8
    mx, my, mw, mh = cfg["layout"]["menu"]
    count = entry_count(cfg)
    # the card hugs the entries; the layout height is only the maximum
    list_h = min(mh, count * (item_h + spacing) + 2 * pad_sel + 16)
    draw_card(img, (mx - pad, my - pad, mw + 2 * pad, list_h + 2 * pad), cfg["card_style"], radius, cfg["card_color"])

    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    img.save(os.path.join(out, "background.jpg"), "JPEG", quality=92, progressive=False, optimize=False)
    json.dump({"kind": "builder", "cfg": cfg}, open(os.path.join(out, MARKER), "w"))
    shutil.copytree(os.path.join(BASE, "icons"), os.path.join(out, "icons"))
    shutil.copy(os.path.join(BASE, "terminus-16.pf2"), out)
    info = Image.open(os.path.join(BASE, "info.png")).convert("RGBA")
    tint = Image.new("RGBA", info.size, hex_rgb(cfg["info_color"]) + (255,))
    tint.putalpha(info.getchannel("A"))
    tint.save(os.path.join(out, "info.png"))
    write_highlight(out, cfg["highlight"], pad_sel, cfg["highlight_style"])
    write_item_pads(out)

    global OUT
    OUT = out
    size = ensure_font(size)
    label_size = ensure_font(max(18, size - 4))
    lay = cfg["layout"]
    ix, iy, iw, ih = lay["info"]
    tx, ty, tw, _ = lay["timeout"]
    theme = f"""# Theme "{name}" generated by grub-custom.py; change settings there, not in this file
title-text: ""
desktop-image: "background.jpg"
desktop-color: "#000000"
terminal-font: "Terminus Regular 16"
terminal-width: "100%"
terminal-height: "100%"
terminal-border: "0"

+ boot_menu {{
  left = {mx}
  top = {my}
  width = {mw}
  height = {list_h}
  item_font = "JB Nerd Regular {size}"
  item_color = "{cfg['text']}"
  selected_item_color = "{cfg['selected_text']}"
  icon_width = {icon}
  icon_height = {icon}
  item_icon_space = 20
  item_height = {item_h}
  item_padding = 8
  item_spacing = {spacing}
  item_pixmap_style = "item_*.png"
  selected_item_pixmap_style = "select_*.png"
}}

+ image {{
  left = {ix}
  top = {iy}
  width = {iw}
  height = {ih}
  file = "info.png"
}}

+ label {{
  left = {tx}
  top = {ty}
  width = {tw}
  align = "center"
  id = "__timeout__"
  text = "{cfg['timeout_text']}"
  color = "{cfg['timeout_color']}"
  font = "JB Nerd Regular {label_size}"
}}
"""
    open(os.path.join(out, "theme.txt"), "w").write(theme)
    preview(name)
    print(f"Built theme '{name}' in {out} ({W}x{H}, {count} entries, card: {cfg['card_style']}, radius {radius})")


OUT = ""


# ---------------------------------------------------------------- variants of existing themes


def themes_root():
    return os.path.join(REPO, "themes")


def marker(name):
    try:
        return json.load(open(os.path.join(themes_root(), name, MARKER)))
    except (OSError, ValueError):
        return None


def list_themes():
    """name<TAB>kind where kind is bundled | variant | builder"""
    for name in sorted(os.listdir(themes_root())):
        if not os.path.isfile(os.path.join(themes_root(), name, "theme.txt")):
            continue
        m = marker(name)
        print(f"{name}\t{m['kind'] if m else 'bundled'}")


def expr_px(expr, total):
    """'100%-50' / '30%' / '470' -> pixels"""
    expr = expr.strip().replace(" ", "")
    value, pos = 0.0, 0
    for sign, num, pct in re.findall(r"([+-]?)(\d+)(%?)", expr):
        n = float(num) * (total / 100 if pct else 1)
        value += -n if sign == "-" else n
    return round(value)


BLOCK = re.compile(r"^\+\s*(\w+)\s*\{(.*?)^\}", re.S | re.M)


def parse_layout(theme_txt, W, H):
    """Read pixel rects for the boot menu, info image and countdown label."""
    text = open(theme_txt).read()
    lay = {}
    for kind, body in ((m.group(1), m.group(2)) for m in BLOCK.finditer(text)):
        props = dict(re.findall(r"^\s*(\w+)\s*=\s*(.+?)\s*$", body, re.M))
        if kind == "boot_menu":
            key = "menu"
        elif kind == "image" and "info" in props.get("file", ""):
            key = "info"
        elif kind == "label" and "__timeout__" in props.get("id", ""):
            key = "timeout"
        else:
            continue
        w = expr_px(props.get("width", "480" if key == "info" else "36%"), W)
        h = expr_px(props.get("height", "42" if key == "info" else "34"), H)
        lay[key] = [expr_px(props.get("left", "0"), W), expr_px(props.get("top", "0"), H), w, h]
    return lay


def write_layout(theme_txt, lay):
    text = open(theme_txt).read()

    def patch(m):
        kind, body = m.group(1), m.group(2)
        props = dict(re.findall(r"^\s*(\w+)\s*=\s*(.+?)\s*$", body, re.M))
        if kind == "boot_menu":
            key = "menu"
        elif kind == "image" and "info" in props.get("file", ""):
            key = "info"
        elif kind == "label" and "__timeout__" in props.get("id", ""):
            key = "timeout"
        else:
            return m.group(0)
        if key not in lay:
            return m.group(0)
        x, y, w, h = lay[key]
        vals = {"left": x, "top": y, "width": w}
        if key != "timeout" or "height" in props:
            vals["height"] = h
        for k, v in vals.items():
            if re.search(rf"^\s*{k}\s*=", body, re.M):
                body = re.sub(rf"^(\s*{k}\s*=).*$", rf"\g<1> {v}", body, flags=re.M)
            else:
                body = f"\n  {k} = {v}" + body
        return f"+ {kind} {{{body}}}"

    open(theme_txt, "w").write(BLOCK.sub(patch, text))


def next_variant_name(base):
    base = re.sub(r"-mine\d+$", "", base)
    n = 1
    while os.path.exists(os.path.join(themes_root(), f"{base}-mine{n}")):
        n += 1
    return f"{base}-mine{n}"


def edit_theme_layout(theme, result_file):
    src = os.path.join(themes_root(), theme)
    if not os.path.isfile(os.path.join(src, "theme.txt")):
        sys.exit(f"unknown theme '{theme}'")
    info = marker(theme)
    if info and info["kind"] == "builder":
        sys.exit("this theme was made by the wallpaper builder: edit its layout from Create a theme > Layout editor")
    res = (info or {}).get("resolution", "1920x1080")
    W, H = parse_res(res)
    lay = parse_layout(os.path.join(src, "theme.txt"), W, H)
    if not lay:
        sys.exit("no boot menu found in theme.txt")
    # editing an existing variant happens in place; bundled themes fork a new -mineN copy
    target = theme if info else next_variant_name(theme)
    base = (info or {}).get("base", theme)
    cfg = {"resolution": res, "layout": lay}

    def save_variant(c):
        dest = os.path.join(themes_root(), target)
        if not os.path.isdir(dest):
            shutil.copytree(src, dest)
            json.dump({"kind": "variant", "base": base, "resolution": res}, open(os.path.join(dest, MARKER), "w"))
            write_item_pads(dest)
            tx = os.path.join(dest, "theme.txt")
            text = open(tx).read()
            open(tx, "w").write(BLOCK.sub(
                lambda m: f"+ {m.group(1)} {{{set_prop(m.group(2), 'item_pixmap_style', 'item_*.png')}}}" if m.group(1) == "boot_menu" else m.group(0),
                text))
        write_layout(os.path.join(dest, "theme.txt"), c["layout"])
        preview(target)

    if curses.wrapper(editor, cfg, save_variant):
        open(result_file, "w").write(target)


STYLE_KEYS = ("text", "selected_text", "highlight", "highlight_style", "card_style", "card_color", "info_color", "timeout_color", "timeout_text", "radius")


def style_load(theme):
    """Write the editable look of an existing custom theme into CFG so the appearance menu can edit it."""
    info = marker(theme)
    if not info:
        sys.exit(f"'{theme}' is not one of your themes")
    if info["kind"] == "builder":
        if "cfg" not in info:
            sys.exit("this theme was built before appearance editing existed: rebuild it once from Create a theme")
        cfg = copy.deepcopy(DEFAULTS)
        saved = dict(info["cfg"])
        cfg["layout"].update(saved.pop("layout", {}))
        cfg.update(saved)
    else:
        text = open(os.path.join(themes_root(), theme, "theme.txt")).read()
        cfg = copy.deepcopy(DEFAULTS)
        cfg["name"] = theme
        found = {
            "text": re.search(r'item_color\s*=\s*"(#[0-9a-fA-F]{6})"', text),
            "selected_text": re.search(r'selected_item_color\s*=\s*"(#[0-9a-fA-F]{6})"', text),
            "timeout_color": re.search(r'__timeout__.*?color\s*=\s*"(#[0-9a-fA-F]{6})"', text, re.S),
            "timeout_text": re.search(r'__timeout__.*?text\s*=\s*"([^"]*%d[^"]*)"', text, re.S),
        }
        cfg["radius"] = 9
        cfg["card_style"] = "invisible"
        for k, m in found.items():
            if m:
                cfg[k] = m.group(1)
        cfg.update(info.get("style", {}))
    save(cfg)


def set_prop(body, key, value):
    if re.search(rf"^\s*{key}\s*=", body, re.M):
        return re.sub(rf"^(\s*{key}\s*=).*$", lambda m: f'{m.group(1)} "{value}"', body, flags=re.M)
    return f'\n  {key} = "{value}"' + body


def restyle(theme, cfg):
    """Apply colors, highlight and countdown text from CFG to an edited copy of a bundled theme."""
    info = marker(theme)
    if not info or info["kind"] != "variant":
        sys.exit(f"'{theme}' is not an edited copy of a bundled theme")
    d = os.path.join(themes_root(), theme)
    tx = os.path.join(d, "theme.txt")
    old = info.get("style", {})

    def patch(m):
        kind, body = m.group(1), m.group(2)
        if kind == "boot_menu":
            body = set_prop(body, "item_color", cfg["text"])
            body = set_prop(body, "selected_item_color", cfg["selected_text"])
            body = set_prop(body, "selected_item_pixmap_style", "select_*.png")
            body = set_prop(body, "item_pixmap_style", "item_*.png")
            if cfg["card_style"] == "invisible":
                body = re.sub(r"^\s*menu_pixmap_style\s*=.*\n", "", body, flags=re.M)
            else:
                body = set_prop(body, "menu_pixmap_style", "menu_*.png")
        elif kind == "label" and "__timeout__" in body:
            body = set_prop(body, "color", cfg["timeout_color"])
            body = set_prop(body, "text", cfg["timeout_text"])
        return f"+ {kind} {{{body}}}"

    new_text = BLOCK.sub(patch, open(tx).read())
    open(tx, "w").write(new_text)
    if cfg["highlight"] != old.get("highlight", "#ffffff") or cfg["radius"] != old.get("radius", 9) or cfg["highlight_style"] != old.get("highlight_style", "full"):
        write_highlight(d, cfg["highlight"], int(cfg["radius"]), cfg["highlight_style"])
    write_item_pads(d)
    write_menu_box(d, cfg["card_color"], int(cfg["radius"]), cfg["card_style"])
    if cfg["info_color"] != old.get("info_color", "#ffffff"):
        img = Image.open(os.path.join(d, "info.png")).convert("RGBA")
        tint = Image.new("RGBA", img.size, hex_rgb(cfg["info_color"]) + (255,))
        tint.putalpha(img.getchannel("A"))
        tint.save(os.path.join(d, "info.png"))
    info["style"] = {k: cfg[k] for k in STYLE_KEYS}
    json.dump(info, open(os.path.join(d, MARKER), "w"))
    preview(theme)
    print(f"Restyled '{theme}'")


# ---------------------------------------------------------------- preview


class Pf2:
    """Minimal GRUB .pf2 reader, so previews use the very glyphs GRUB will draw."""

    def __init__(self, path):
        d = open(path, "rb").read()
        self.d, self.idx, self.name = d, {}, ""
        self.asc = self.desc = 0
        i = 0
        while i < len(d):
            tag, ln = d[i:i + 4], int.from_bytes(d[i + 4:i + 8], "big")
            body = d[i + 8:i + 8 + ln]
            if tag == b"NAME":
                self.name = body.rstrip(b"\0").decode()
            elif tag == b"ASCE":
                self.asc = int.from_bytes(body, "big")
            elif tag == b"DESC":
                self.desc = int.from_bytes(body, "big")
            elif tag == b"CHIX":
                for j in range(0, ln, 9):
                    self.idx[int.from_bytes(body[j:j + 4], "big")] = int.from_bytes(body[j + 5:j + 9], "big")
            if tag == b"DATA":
                break
            i += 8 + ln

    def glyph(self, ch):
        off = self.idx.get(ord(ch))
        if off is None:
            return None
        d = self.d
        w, h = int.from_bytes(d[off:off + 2], "big"), int.from_bytes(d[off + 2:off + 4], "big")
        xo, yo, dw = (int.from_bytes(d[off + k:off + k + 2], "big", signed=True) for k in (4, 6, 8))
        bits = d[off + 10:off + 10 + (w * h + 7) // 8]
        return w, h, xo, yo, dw, bits

    def width(self, text):
        return sum((self.glyph(c) or (0, 0, 0, 0, 0, b""))[4] for c in text)

    def draw(self, img, x, y, text, color):
        """Draw text with its line box starting at y."""
        pen, base = x, y + self.asc
        for c in text:
            g = self.glyph(c)
            if not g:
                continue
            w, h, xo, yo, dw, bits = g
            mask = Image.new("L", (max(w, 1), max(h, 1)), 0)
            px = mask.load()
            for n in range(w * h):
                if bits[n >> 3] & (0x80 >> (n & 7)):
                    px[n % w, n // w] = 255
            img.paste(Image.new("RGBA", mask.size, color + (255,)), (pen + xo, base - yo - h), mask)
            pen += dw


def theme_fonts(d):
    fonts = {}
    for f in glob.glob(os.path.join(d, "*.pf2")):
        try:
            fonts[Pf2(f).name] = f
        except Exception:
            pass
    return fonts


def paste_box(img, d, prefix, rect):
    """Draw a GRUB nine-slice style (prefix_*.png) around rect = (x, y, w, h)."""
    tiles = {n: Image.open(os.path.join(d, f"{prefix}_{n}.png")).convert("RGBA")
             for n in NINE if os.path.isfile(os.path.join(d, f"{prefix}_{n}.png"))}
    if not tiles:
        return
    x, y, w, h = rect
    lw = tiles["w"].width if "w" in tiles else 0
    rw = tiles["e"].width if "e" in tiles else 0
    th = tiles["n"].height if "n" in tiles else 0
    bh = tiles["s"].height if "s" in tiles else 0
    x0, y0, x1, y1 = x - lw, y - th, x + w + rw, y + h + bh
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))

    def put(name, bx, by, bw, bh_):
        if name in tiles and bw > 0 and bh_ > 0:
            layer.alpha_composite(tiles[name].resize((bw, bh_), Image.NEAREST), (bx, by))

    put("c", x0 + lw, y0 + th, x1 - x0 - lw - rw, y1 - y0 - th - bh)
    put("w", x0, y0 + th, lw, y1 - y0 - th - bh)
    put("e", x1 - rw, y0 + th, rw, y1 - y0 - th - bh)
    put("n", x0 + lw, y0, x1 - x0 - lw - rw, th)
    put("s", x0 + lw, y1 - bh, x1 - x0 - lw - rw, bh)
    for name, bx, by in (("nw", x0, y0), ("ne", x1 - rw, y0), ("sw", x0, y1 - bh), ("se", x1 - rw, y1 - bh)):
        if name in tiles:
            layer.alpha_composite(tiles[name], (bx, by))
    img.alpha_composite(layer)


def preview(theme):
    """Render previews/<theme>.png from the installed theme files (background, boot menu, icons, info bar, countdown)."""
    d = os.path.join(themes_root(), theme)
    text = open(os.path.join(d, "theme.txt")).read()
    img = Image.open(os.path.join(d, "background.jpg")).convert("RGBA")
    W, H = img.size
    fonts = theme_fonts(d)
    entries = [("Arch Linux", "arch"), ("Advanced options for Arch Linux", "gnu-linux"),
               ("Windows Boot Manager", "windows"), ("UEFI Firmware Settings", "efi")]
    for m in BLOCK.finditer(text):
        kind = m.group(1)
        props = {k: v.strip('"') for k, v in re.findall(r"^\s*(\w+)\s*=\s*(.+?)\s*$", m.group(2), re.M)}
        px = lambda k, total, default="0": expr_px(props.get(k, default), total)
        x, y = px("left", W), px("top", H)
        if kind == "boot_menu":
            w, h = px("width", W), px("height", H)
            ih, sp, pad = px("item_height", H, "36"), px("item_spacing", H, "16"), px("item_padding", W, "8")
            iw, isp = px("icon_width", W, "32"), px("item_icon_space", W, "20")
            font = Pf2(fonts[props["item_font"]]) if props.get("item_font") in fonts else None
            if "menu_pixmap_style" in props:
                paste_box(img, d, "menu", (x, y, w, h))
            for n, (label, icon) in enumerate(entries):
                iy = y + n * (ih + sp)
                if iy + ih > y + h + ih:
                    break
                sel = n == 0
                if sel:
                    paste_box(img, d, "select", (x, iy, w, ih))
                ic = os.path.join(d, "icons", icon + ".png")
                if os.path.isfile(ic) and iw:
                    pic = Image.open(ic).convert("RGBA").resize((iw, iw), Image.LANCZOS)
                    img.alpha_composite(pic, (x + pad, iy + (ih - iw) // 2))
                if font:
                    col = hex_rgb(props["selected_item_color" if sel else "item_color"])
                    font.draw(img, x + pad + iw + isp, iy + (ih - font.asc - font.desc) // 2, label, col)
        elif kind == "image":
            f = os.path.join(d, props.get("file", ""))
            if os.path.isfile(f):
                pic = Image.open(f).convert("RGBA")
                w, h = px("width", W, str(pic.width)), px("height", H, str(pic.height))
                img.alpha_composite(pic.resize((w, h), Image.LANCZOS), (x, y))
        elif kind == "label" and props.get("id") == "__timeout__" and props.get("font") in fonts:
            font = Pf2(fonts[props["font"]])
            label = props.get("text", "").replace("%d", "5")
            w = px("width", W, "36%")
            font.draw(img, x + (w - font.width(label)) // 2, y, label, hex_rgb(props.get("color", "#ffffff")))
    out = os.path.join(REPO, "previews")
    os.makedirs(out, exist_ok=True)
    img.convert("RGB").resize((1280, round(1280 * H / W)), Image.LANCZOS).save(os.path.join(out, f"{theme}.png"), optimize=True)
    print(f"Preview: previews/{theme}.png")


def delete_theme(name):
    info = marker(name)
    if not info or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
        sys.exit(f"'{name}' is not one of your themes (bundled themes cannot be deleted)")
    shutil.rmtree(os.path.join(themes_root(), name))
    try:
        os.remove(os.path.join(REPO, "previews", f"{name}.png"))
    except OSError:
        pass
    print(f"Deleted theme '{name}'")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args, cfg = sys.argv[1], sys.argv[2:], load()
    if cmd == "get":
        print(cfg[args[0]])
    elif cmd == "show":
        for k, v in cfg.items():
            print(f"{k} = {v}")
    elif cmd == "resolutions":
        print("\n".join(RESOLUTIONS), "(any WxH works)", sep="\n")
    elif cmd == "set":
        key, value = args[0], " ".join(args[1:])
        if key == "resolution":
            parse_res(value)
            rescale(cfg, value)
        elif key in ("text", "selected_text", "highlight", "card_color", "info_color", "timeout_color"):
            cfg[key] = check_color(value)
        elif key == "name":
            cfg[key] = check_name(value)
        elif key in ("card_style", "highlight_style"):
            if value not in ("blurry", "full", "invisible"):
                sys.exit(f"{key} must be blurry, full or invisible")
            cfg[key] = value
        elif key in ("item_spacing", "icon_size"):
            lo, hi = (0, 40) if key == "item_spacing" else (16, 96)
            if not value.isdigit() or not lo <= int(value) <= hi:
                sys.exit(f"{key} must be {lo}-{hi}")
            cfg[key] = int(value)
        elif key == "timeout_text":
            if value.count("%d") != 1 or '"' in value:
                sys.exit('timeout_text must contain %d once and no double quotes')
            cfg[key] = value
        elif key == "radius":
            if not value.isdigit() or int(value) > 80:
                sys.exit("radius must be 0-80")
            cfg[key] = int(value)
        elif key == "entries":
            if value != "auto" and not value.isdigit():
                sys.exit("entries must be 'auto' or a number")
            cfg[key] = value if value == "auto" else int(value)
        elif key == "font_size":
            if not value.isdigit() or not 12 <= int(value) <= 64:
                sys.exit("font_size must be 12-64")
            cfg[key] = int(value)
        elif key == "wallpaper":
            cfg[key] = os.path.abspath(os.path.expanduser(value))
            if not os.path.isfile(cfg[key]):
                sys.exit(f"file not found: {cfg[key]}")
        else:
            sys.exit(f"unknown setting '{key}'")
        save(cfg)
    elif cmd == "layout":
        curses.wrapper(editor, cfg)
    elif cmd == "list":
        list_themes()
    elif cmd == "edit":
        edit_theme_layout(args[0], args[1])
    elif cmd == "style-load":
        style_load(args[0])
    elif cmd == "restyle":
        restyle(args[0], cfg)
    elif cmd == "delete":
        delete_theme(args[0])
    elif cmd == "preview":
        for t in args or [t for t in os.listdir(themes_root()) if os.path.isfile(os.path.join(themes_root(), t, "theme.txt"))]:
            preview(t)
    elif cmd == "build":
        build(cfg)
    else:
        sys.exit(__doc__)


main()
