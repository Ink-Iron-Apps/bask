#!/usr/bin/env python3
"""Render every committed Bask icon from the two master SVGs.

The masters are ``assets/bask_adaptive_foreground.svg`` (the mark, on the 108
unit canvas Android's adaptive icon uses) and the ink colour it sits on. Every
raster here is composed from that one body, so the app cannot end up with two
different logos again — which is exactly what it had before, a teal mark in
the app and an orange one on the home screen.

Needs ``rsvg-convert`` (librsvg) and ``convert`` plus ``icotool`` (ImageMagick
and icoutils). Run it from the repository root:

    python3 scripts/codegen/generate_brand_icons.py
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The ink the mark sits on, matching @color/ic_launcher_background and the
# app's own background. Kept here as the single place a backplate is named.
INK = "#0F1115"

# How much of a square the mark occupies. 2/3 is Android's adaptive safe
# zone, which the master is already drawn to; the backplated rasters use a
# little more because nothing is going to mask them.
MASKED_SCALE = 2 / 3
PLATED_SCALE = 0.74

MARK_SVG = ROOT / "assets/bask_adaptive_foreground.svg"


def require(*tools: str) -> None:
    missing = [tool for tool in tools if shutil.which(tool) is None]
    if missing:
        sys.exit(
            f"Missing {', '.join(missing)}. On Debian or Ubuntu: "
            "sudo apt install librsvg2-bin imagemagick icoutils"
        )


def mark_body() -> str:
    """The master's drawing instructions, without its own <svg> wrapper."""
    source = MARK_SVG.read_text(encoding="utf-8")
    body = re.search(r"<svg\b[^>]*>(.*)</svg>", source, re.DOTALL)
    if body is None:
        sys.exit(f"{MARK_SVG} does not look like an SVG")
    return body.group(1)


def compose(body: str, *, width: int, height: int, scale: float, plate: str | None) -> str:
    """Place the mark on a canvas of any shape, optionally on a backplate.

    The mark is drawn in a 108 unit square and is centred on the short edge,
    so wide canvases — a tvOS top shelf, a Windows splash — get the same mark
    with more room around it rather than a stretched one.
    """
    edge = min(width, height) * scale
    unit = edge / 72  # The mark's own 66 units plus a little air.
    left = (width - 108 * unit) / 2
    top = (height - 108 * unit) / 2
    backplate = f'<rect width="{width}" height="{height}" fill="{plate}"/>' if plate else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">{backplate}'
        f'<g transform="translate({left:.4f} {top:.4f}) scale({unit:.6f})">{body}</g></svg>'
    )


def rounded_square(body: str, size: int) -> str:
    """The launcher icon as a platform that does no masking wants it."""
    unit = size * PLATED_SCALE / 72
    offset = (size - 108 * unit) / 2
    radius = size * 24 / 108
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
        f'viewBox="0 0 {size} {size}">'
        f'<rect width="{size}" height="{size}" rx="{radius:.4f}" fill="{INK}"/>'
        f'<g transform="translate({offset:.4f} {offset:.4f}) scale({unit:.6f})">{body}</g></svg>'
    )


def render(svg: str, destination: Path, width: int, height: int, workdir: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = workdir / "frame.svg"
    source.write_text(svg, encoding="utf-8")
    subprocess.run(
        ["rsvg-convert", "-w", str(width), "-h", str(height), "-o", str(destination), str(source)],
        check=True,
    )
    label = destination.relative_to(ROOT) if destination.is_relative_to(ROOT) else destination.name
    print(f"  {label} ({width}x{height})")


def main() -> int:
    require("rsvg-convert", "convert", "icotool")
    body = mark_body()

    with tempfile.TemporaryDirectory(prefix="bask-icons-") as temp:
        workdir = Path(temp)

        print("App asset, the source every packager reads:")
        render(compose(body, width=1024, height=1024, scale=0.92, plate=None),
               ROOT / "assets/bask_icon.png", 1024, 1024, workdir)

        print("Android launcher rasters, for the launchers with no adaptive support:")
        for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
            render(rounded_square(body, size),
                   ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png", size, size, workdir)

        print("Windows executable icon:")
        ico_frames = []
        for size in (16, 24, 32, 48, 64, 128, 256):
            frame = workdir / f"ico-{size}.png"
            render(rounded_square(body, size), frame, size, size, workdir)
            ico_frames.append(str(frame))
        destination = ROOT / "windows/runner/resources/app_icon.ico"
        subprocess.run(["icotool", "-c", "-o", str(destination), *ico_frames], check=True)
        print(f"  {destination.relative_to(ROOT)}")

        print("Windows MSIX tiles, which the manifest draws on its own background:")
        tiles = {
            "Square44x44Logo.png": (44, 44),
            "Square150x150Logo.png": (150, 150),
            "StoreLogo.png": (50, 50),
            "Wide310x150Logo.png": (310, 150),
            "Square310x310Logo.png": (310, 310),
            "SplashScreen.png": (620, 300),
            "Square44x44Logo.scale-200.png": (88, 88),
            "Square150x150Logo.scale-200.png": (300, 300),
        }
        for size in (16, 24, 32, 48, 256):
            for form in ("", "_altform-unplated", "_altform-lightunplated"):
                tiles[f"Square44x44Logo.targetsize-{size}{form}.png"] = (size, size)
        for name, (width, height) in sorted(tiles.items()):
            render(compose(body, width=width, height=height, scale=0.78, plate=None),
                   ROOT / "windows/msix/assets" / name, width, height, workdir)

        print("tvOS layered icon and top shelf:")
        stacks = {
            "App Icon.imagestack": [("", 400, 240), ("@2x", 800, 480)],
            "App Icon - App Store.imagestack": [("", 1280, 768)],
        }
        brand = ROOT / "tvos/Runner/Assets.xcassets/AppIcon.brandassets"
        for stack, variants in stacks.items():
            for suffix, width, height in variants:
                layers = {
                    "Back": compose(body, width=width, height=height, scale=0, plate=INK),
                    # Deliberately empty: the parallax reads as the mark
                    # lifting off a flat ground, not as three stacked marks.
                    "Middle": compose(body, width=width, height=height, scale=0, plate=None),
                    "Front": compose(body, width=width, height=height, scale=MASKED_SCALE, plate=None),
                }
                for layer, svg in layers.items():
                    path = brand / stack / f"{layer}.imagestacklayer/Content.imageset/{layer}{suffix}.png"
                    if path.exists() or layer != "Middle" or suffix == "":
                        render(svg, path, width, height, workdir)
        for name, width, height in [
            ("Top Shelf Image.imageset/top-shelf.png", 1920, 720),
            ("Top Shelf Image Wide.imageset/top-shelf-wide.png", 2320, 720),
            ("Top Shelf Image Wide.imageset/top-shelf-wide@2x.png", 4640, 1440),
        ]:
            render(compose(body, width=width, height=height, scale=0.52, plate=INK),
                   brand / name, width, height, workdir)

    print("\nStill generated separately: Android's monochrome and notification "
          "icons, by scripts/codegen/generate_android_icons.sh from "
          "assets/bask_silhouette.svg.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
