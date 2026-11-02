# grub-theme-tui

Fork of [vinceliuice/grub2-themes](https://github.com/vinceliuice/grub2-themes), now with a TUI to customize themes and a simple installer.

| Theme | Preview |
|---|---|
| gruvbox | ![gruvbox](previews/gruvbox.png) |
| windows | ![windows](previews/windows.png) |
| cat | ![cat](previews/cat.png) |

## Requirements
- bash, sudo, GRUB (`grub-mkconfig`, `grub2-mkconfig` or `update-grub`)
- python3 + **Pillow** (`pip install -r requirements.txt`)

## TUI
```sh
./grub-tui.sh
```
Install, create, edit and delete themes. Previews are regenerated on every change.

| Menu | Layout editor |
|---|---|
| ![TUI menu](screenshots/tui-menu.png) | ![Layout editor](screenshots/tui-layout.png) |

## Without the TUI
```sh
sudo ./install.sh -t gruvbox                  # install a theme
sudo ./install.sh -t windows -c 2560x1440     # set resolution (any WxH)
sudo ./install.sh -r gruvbox                  # remove
./install.sh -l                               # list themes
```
```
-t THEME     theme to install          -c WxH      resolution (any)
-i SET       icons: color|white|whitesur  -T SECS  boot timeout (-1 = wait)
-r THEME     remove a theme            -U          uninstall all, restore defaults
-s           re-apply hidden entries   -g DIR      copy theme only
-l           list themes               -u          interactive menu
-h           help
```

Customize by hand: edit `themes/<name>/theme.txt`, then re-run the installer.

## Make a theme from the command line
`./grub-custom.py set KEY VALUE` saves a setting, `build` creates `themes/<name>` and `previews/<name>.png`, then install it.

```sh
# minimal: wallpaper + name
./grub-custom.py set name mytheme
./grub-custom.py set wallpaper ~/pic.jpg
./grub-custom.py build
sudo ./install.sh -t mytheme

# 1440p, solid dark card, blue highlight
./grub-custom.py set name dark
./grub-custom.py set wallpaper ~/pic.jpg
./grub-custom.py set resolution 2560x1440
./grub-custom.py set card_style full
./grub-custom.py set card_color "#1e1e2e"
./grub-custom.py set text "#cdd6f4"
./grub-custom.py set selected_text "#1e1e2e"
./grub-custom.py set highlight "#89b4fa"
./grub-custom.py set radius 20
./grub-custom.py build
sudo ./install.sh -t dark -c 2560x1440

# glass card, outline highlight, custom countdown
./grub-custom.py set name glass
./grub-custom.py set card_style blurry
./grub-custom.py set highlight_style invisible
./grub-custom.py set timeout_text "Booting in %d..."
./grub-custom.py build
```

Other commands: `show` (all settings), `get KEY`, `resolutions`, `list`, `preview [THEME]`, `delete NAME`.

| Setting | Values |
|---|---|
| `name` | letters, digits, `-`, `_` |
| `wallpaper` | any image (png, jpg, webp, bmp, gif, tiff) |
| `resolution` | `1280x720` `1366x768` `1600x900` `1920x1080` `1920x1200` `2560x1080` `2560x1440` `2560x1600` `3440x1440` `3840x2160`, or any `WxH` |
| `card_style` | `blurry` `full` `invisible` |
| `highlight_style` | `blurry` `full` `invisible` |
| `card_color` `text` `selected_text` `highlight` `info_color` `timeout_color` | `#rrggbb` |
| `radius` | 0-80 |
| `font_size` | 12-64 |
| `item_spacing` | 0-40 |
| `icon_size` | 16-96 |
| `entries` | `auto` or a number (sizes the card) |
| `timeout_text` | text containing `%d` once |

Settings are kept in `~/.cache/grub-theme-tui/working.json`.

## Themes
One folder per theme in `themes/`. Themes you make or edit also get a `theme.json` with their settings, and a preview in `previews/`.

Original themes by Vince Liuice, GPL-3.0.
