#!/usr/bin/env python3
"""Crops one capture run into the files the website uses.

    crop-screenshots.py <run-dir> <dest-dir> <variant>

<run-dir> holds the full-stage PNGs and bounds.json that shots-driver wrote.
Every output is <name>-<variant>.webp in <dest-dir>.
"""

import json
import pathlib
import subprocess
import sys

# Wallpaper left around a popover or window, in logical pixels, the same on
# every side. 16 is all the room there is right of the popover (GNOME keeps it
# 16 px from the screen edge); styles.css's .shot-* frame radii assume it.
PADDING = 16
# A crop that would cut through the top bar takes all of it instead.
PANEL_HEIGHT = 40
# shot -> output name, each cropped to its bounds in bounds.json: the popover,
# the dashboard or the Settings window, and for "desktop" the screen down to
# just below the open popover and dashboard.
CROPS = {
    "popover-all": "popover",
    "popover-claude": "provider-claude",
    "cost-dashboard": "dashboard",
    "machines": "machines",
    "settings": "settings",
    "settings-sync": "settings-sync",
    "desktop": "desktop",
}


# Surfaces shown on their own: cut out exactly, no wallpaper or top bar, with
# their rounded corners made transparent. Value: the corner radius in logical
# pixels (the dashboard copies the popover's 20; libadwaita windows use 15).
CUTOUTS = {
    "cost-dashboard": 20,
    "settings": 15,
    "settings-sync": 15,
}


def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)


def main():
    run_dir, dest_dir, variant = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
    bounds = json.loads((run_dir / "bounds.json").read_text())
    scale = bounds["scale"]
    stage = bounds["stage"]
    dest_dir.mkdir(parents=True, exist_ok=True)
    quality = ["-quality", "92", "-define", "webp:method=6"]
    offscreen = [
        f"{shot} ends at x={rect['x'] + rect['width']}, y={rect['y'] + rect['height']}"
        for shot, rect in bounds["shots"].items()
        if rect["x"] < 0 or rect["y"] < 0
        or rect["x"] + rect["width"] > stage["width"] or rect["y"] + rect["height"] > stage["height"]
    ]
    if offscreen:
        # Cropping would cut the surface's edge off; make the virtual screen
        # in capture-screenshots.sh bigger instead.
        sys.exit(f"shots run off the {stage['width']}x{stage['height']} screen: " + "; ".join(offscreen))
    for shot, name in CROPS.items():
        rect = bounds["shots"][shot]
        if shot in CUTOUTS:
            x, y = round(rect["x"] * scale), round(rect["y"] * scale)
            w, h = round(rect["width"] * scale), round(rect["height"] * scale)
            r = round(CUTOUTS[shot] * scale)
            magick(run_dir / f"{shot}.png", "-crop", f"{w}x{h}+{x}+{y}", "+repage",
                   "(", "-size", f"{w}x{h}", "xc:black", "-fill", "white",
                   "-draw", f"roundrectangle 0,0,{w - 1},{h - 1},{r},{r}", ")",
                   "-alpha", "off", "-compose", "CopyOpacity", "-composite",
                   *quality, dest_dir / f"{name}-{variant}.webp")
            continue
        full_width = rect["width"] >= stage["width"]
        pad = 0 if full_width else PADDING
        left = rect["x"] - pad
        top = rect["y"] - pad
        right = rect["x"] + rect["width"] + pad
        bottom = rect["y"] + rect["height"] + pad
        # Clamping one side would make the padding uneven; stop instead.
        if not full_width and shot != "desktop" and (
                left < 0 or right > stage["width"] or bottom > stage["height"]):
            sys.exit(f"{shot}: no room for {pad} px of wallpaper on every side "
                     f"(x {left}..{right}, bottom {bottom}, screen {stage['width']}x{stage['height']})")
        left, top = max(0, left), max(0, top)
        right, bottom = min(stage["width"], right), min(stage["height"], bottom)
        if top < PANEL_HEIGHT:
            top = 0
        geometry = f"{round((right - left) * scale)}x{round((bottom - top) * scale)}" \
                   f"+{round(left * scale)}+{round(top * scale)}"
        magick(run_dir / f"{shot}.png", "-crop", geometry, "+repage", *quality,
               dest_dir / f"{name}-{variant}.webp")
    print(f"cropped {len(CROPS)} {variant} screenshots into {dest_dir}")


if __name__ == "__main__":
    main()
