#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Build the tvOS brand assets from the icon layers that design/icon/bookworms.py renders."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
LAYERS = ROOT / "design/icon/layers"
INFO = {"author": "gay.ian.Bookworms", "version": 1}
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
# The icon's cream, top to bottom; the iPhone and Mac icon uses the same gradient.
PAPER = ("#FCF3E0", "#EFE0C2")


def write_json(folder, value):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps(value, indent=2) + "\n")


def paper(size):
    ramp = Image.linear_gradient("L").resize(size)
    return Image.composite(Image.new("RGB", size, PAPER[1]), Image.new("RGB", size, PAPER[0]), ramp)


def badge(image, left):
    """Draws a device install's LOCAL badge on the book's cover, where it hides neither worm.

    left is the badge's distance from the image's left edge, in points of a 768-point-high frame.
    """
    scale = image.height / 768
    box = [value * scale for value in (left, 608, left + 288, 714)]
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(box, 26 * scale, fill="#14595B")
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", round(61 * scale), index=1)
    draw.text(((box[0] + box[2]) / 2, (box[1] + box[3]) / 2), "LOCAL", font=font, fill="white", anchor="mm")


def save(image, path, size):
    """Writes image at size with an sRGB profile; a layer must keep some transparency."""
    path.parent.mkdir(parents=True, exist_ok=True)
    image = image.resize(size, Image.LANCZOS)
    if image.mode == "RGBA" and image.getextrema()[3][0] == 255:
        raise ValueError(f"{path.name} should be a transparent layer, but it is opaque")
    image.save(path, icc_profile=SRGB)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local", action="store_true",
                        help="Generate the LOCAL-badged device-install icon without changing release assets")
    args = parser.parse_args()
    output = ROOT / "Bookworms/Assets.xcassets" / (
        "Local App Icon.brandassets" if args.local else "App Icon & Top Shelf Image.brandassets")

    book = Image.open(LAYERS / "tv-book.png").convert("RGBA")
    worms = Image.open(LAYERS / "tv-worms.png").convert("RGBA")
    shelf = paper((4640, 1440)).convert("RGBA")
    shelf.alpha_composite(Image.open(LAYERS / "shelf.png").convert("RGBA"))
    if args.local:
        badge(book, 928)
        badge(shelf, 768 * shelf.width / shelf.height / 2 + 96)
    # Xcode expects layer order from front to back.
    layers = [("book", "Front", book), ("worms", "Middle", worms), ("background", "Back", paper(book.size))]

    assets = []
    for name, width, height, scales in [("App Icon", 400, 240, (1, 2)), ("App Icon - App Store", 1280, 768, (1,))]:
        stack = output / f"{name}.imagestack"
        assets.append({"idiom": "tv", "size": f"{width}x{height}", "filename": stack.name, "role": "primary-app-icon"})
        write_json(stack, {"info": INFO, "layers": [{"filename": f"{place}.imagestacklayer"} for _, place, _ in layers]})
        for layer, place, image in layers:
            folder = stack / f"{place}.imagestacklayer"
            write_json(folder, {"info": INFO})
            content = folder / "Content.imageset"
            images = []
            for scale in scales:
                filename = f"{layer}@{scale}x.png"
                images.append({"idiom": "tv", "filename": filename, "scale": f"{scale}x"})
                save(image, content / filename, (width * scale, height * scale))
            write_json(content, {"images": images, "info": INFO})

    # Static brand fallback for when the dynamic Top Shelf extension has no content. The standard
    # image is the middle of the wide one, so the worms stay centered in both.
    for name, width, role in [("Top Shelf Image", 1920, "top-shelf-image"),
                              ("Top Shelf Image Wide", 2320, "top-shelf-image-wide")]:
        folder = output / f"{name}.imageset"
        assets.append({"idiom": "tv", "size": f"{width}x720", "filename": folder.name, "role": role})
        inset = (shelf.width - width * 2) // 2
        banner = shelf.crop((inset, 0, shelf.width - inset, shelf.height)).convert("RGB")
        images = []
        for scale in (1, 2):
            filename = f"top-shelf@{scale}x.png"
            images.append({"idiom": "tv", "filename": filename, "scale": f"{scale}x"})
            save(banner, folder / filename, (width * scale, 720 * scale))
        write_json(folder, {"images": images, "info": INFO})
    write_json(output, {"assets": assets, "info": INFO})

    preview = layers[2][2].convert("RGBA")
    preview.alpha_composite(worms)
    preview.alpha_composite(book)
    name = "bookworms-local-preview.png" if args.local else "bookworms-preview.png"
    save(preview.convert("RGB"), ROOT / "design/icon" / name, preview.size)
    print(f"tvOS brand assets: {output.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
