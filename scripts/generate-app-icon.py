#!/usr/bin/env python3
"""Export the SVG into tvOS brand assets. Requires Node.js and sharp."""

import argparse
import copy
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design/icon/bookworms.svg"
OUTPUT = ROOT / "Bookworms/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
INFO = {"author": "gay.ian.Bookworms", "version": 1}
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)
ET.register_namespace("inkscape", "http://www.inkscape.org/namespaces/inkscape")


def write_json(folder, value):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps(value, indent=2) + "\n")


def svg_text(source, width, height, layer=None):
    root = copy.deepcopy(source)
    root.set("width", str(width))
    root.set("height", str(height))
    if layer:
        for child in list(root):
            if child.tag == f"{{{SVG}}}g" and child.get("id") != layer:
                root.remove(child)
    return ET.tostring(root, encoding="unicode")


def main():
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", default="node", help="Node executable; use NODE_PATH for sharp if needed")
    parser.add_argument("--local", action="store_true", help="Generate the LOCAL-badged device-install icon without changing release assets")
    args = parser.parse_args()
    if args.local:
        OUTPUT = ROOT / "Bookworms/Assets.xcassets/Local App Icon.brandassets"
    source = ET.parse(SOURCE).getroot()
    layers = [("book", "Front"), ("worms", "Middle"), ("background", "Back")]
    group_ids = [child.get("id") for child in source if child.tag == f"{{{SVG}}}g"]
    if set(group_ids) != {layer for layer, _ in layers}:
        raise ValueError("Expected exactly background, worms, and book SVG groups")

    if args.local:
        front = next(group for group in source if group.get("id") == "book")
        badge = ET.SubElement(front, f"{{{SVG}}}g", {"stroke": "none"})
        ET.SubElement(badge, f"{{{SVG}}}rect", {"x": "540", "y": "60", "width": "180", "height": "66", "rx": "16", "fill": "#14595B"})
        label = ET.SubElement(badge, f"{{{SVG}}}text", {"x": "630", "y": "105", "text-anchor": "middle", "font-family": "Helvetica, Arial, sans-serif", "font-size": "38", "font-weight": "700", "fill": "#FFFFFF"})
        label.text = "LOCAL"

    jobs = []
    assets = []
    for name, width, height, scales in [
        ("App Icon", 400, 240, (1, 2)),
        ("App Icon - App Store", 1280, 768, (1,)),
    ]:
        stack = OUTPUT / f"{name}.imagestack"
        assets.append({"idiom": "tv", "size": f"{width}x{height}",
                       "filename": stack.name, "role": "primary-app-icon"})
        # Xcode expects layer order from front to back.
        write_json(stack, {"info": INFO, "layers": [
            {"filename": f"{name}.imagestacklayer"} for _, name in layers
        ]})
        for layer, layer_name in layers:
            folder = stack / f"{layer_name}.imagestacklayer"
            write_json(folder, {"info": INFO})
            content = folder / "Content.imageset"
            images = []
            for scale in scales:
                filename = f"{layer}@{scale}x.png"
                images.append({"idiom": "tv", "filename": filename, "scale": f"{scale}x"})
                jobs.append({"svg": svg_text(source, width * scale, height * scale, layer),
                             "output": str(content / filename), "opaque": layer == "background",
                             "width": width * scale, "height": height * scale})
            write_json(content, {"images": images, "info": INFO})

    # Static brand fallback for when the dynamic Top Shelf extension has no content.
    # Keep the artwork centered and undistorted on the wide cream canvas.
    for name, width, role in [("Top Shelf Image", 1920, "top-shelf-image"),
                              ("Top Shelf Image Wide", 2320, "top-shelf-image-wide")]:
        height = 720
        folder = OUTPUT / f"{name}.imageset"
        images = []
        assets.append({"idiom": "tv", "size": f"{width}x{height}",
                       "filename": folder.name, "role": role})
        for scale in (1, 2):
            filename = f"top-shelf@{scale}x.png"
            images.append({"idiom": "tv", "filename": filename, "scale": f"{scale}x"})
            canvas_width = width * 480 / height
            offset = (canvas_width - 800) / 2
            banner = copy.deepcopy(source)
            banner.set("viewBox", f"0 0 {canvas_width} 480")
            for group in banner.findall(f"{{{SVG}}}g"):
                if group.get("id") == "background":
                    group[0].set("d", f"M0 0H{canvas_width}V480H0Z")
                else:
                    group.set("transform", f"translate({offset} 0)")
            jobs.append({"svg": svg_text(banner, width * scale, height * scale),
                         "output": str(folder / filename), "opaque": True,
                         "width": width * scale, "height": height * scale})
        write_json(folder, {"images": images, "info": INFO})

    write_json(OUTPUT, {"assets": assets, "info": INFO})
    layer_folder = ROOT / ("design/icon/local-layers" if args.local else "design/icon/layers")
    layer_folder.mkdir(parents=True, exist_ok=True)
    for layer, _ in layers:
        (layer_folder / f"{layer}.svg").write_text(svg_text(source, 1280, 768, layer) + "\n")
    jobs.append({"svg": svg_text(source, 1280, 768),
                 "output": str(ROOT / ("design/icon/bookworms-local-preview.png" if args.local else "design/icon/bookworms-preview.png")),
                 "opaque": True, "width": 1280, "height": 768})

    renderer = r"""
const fs = require('node:fs');
const sharp = require('sharp');
(async () => {
  const jobs = JSON.parse(fs.readFileSync(0, 'utf8'));
  for (const job of jobs) {
    let image = sharp(Buffer.from(job.svg)).toColourspace('srgb');
    image = job.opaque ? image.removeAlpha() : image.ensureAlpha();
    await image.withIccProfile('srgb').png().toFile(job.output);
    const metadata = await sharp(job.output).metadata();
    const stats = await sharp(job.output).stats();
    if (metadata.width !== job.width || metadata.height !== job.height || !metadata.icc) {
      throw new Error(`Invalid dimensions or missing sRGB profile: ${job.output}`);
    }
    if (job.opaque ? metadata.hasAlpha : (!metadata.hasAlpha || stats.isOpaque)) {
      throw new Error(`Invalid layer transparency: ${job.output}`);
    }
  }
  console.log(`Generated and verified ${jobs.length} PNGs: dimensions, sRGB, and transparency.`);
})().catch(error => { console.error(error); process.exit(1); });
"""
    subprocess.run([args.node, "-e", renderer], input=json.dumps(jobs), text=True, check=True)
    print(f"tvOS brand assets: {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
