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
sudo ./install.sh -t windows -c 1920x1080     # set resolution
sudo ./install.sh -r gruvbox                  # remove
./install.sh -l                               # list themes
```
Other flags: `-i color|white|whitesur` (icons), `-g DIR` (copy only).

Customize by hand: edit `themes/<name>/theme.txt`, then re-run the installer.
Or script the builder:
```sh
./grub-custom.py set wallpaper ~/pic.jpg
./grub-custom.py set name mytheme
./grub-custom.py build            # creates themes/mytheme + previews/mytheme.png
./grub-custom.py preview          # re-render all previews
```

## Themes
One folder per theme in `themes/`. Themes you make or edit also get a `theme.json` with their settings, and a preview in `previews/`.

Original themes by Vince Liuice, GPL-3.0.
