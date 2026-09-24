# Bookworms tvOS icon

[`bookworms.svg`](bookworms.svg) is the editable source: two pink worms sharing an open purple book. Cream pages sit behind the purple cover. Segment strokes use 50% opacity; outer outlines, smiles, and eyes are opaque. The SVG has no embedded raster images, font dependencies, or external resources.

## Generated assets

The app uses `Bookworms/Assets.xcassets/App Icon & Top Shelf Image.brandassets`, selected by `ASSETCATALOG_COMPILER_APPICON_NAME` in both the Xcode project and `project.yml`.

- Home Screen: 400 × 240 and 800 × 480 PNGs, each with three layers.
- App Store: 1280 × 768 PNGs with the same three layers.
- Layer order, front to back: purple book, pink worms, cream background.
- Standard and wide static Top Shelf fallbacks: 1920 × 720 and 2320 × 720, plus their 2× variants. These center the artwork without stretching it. The existing dynamic Top Shelf extension continues to provide selected books.
- Each PNG includes an sRGB profile. Background and Top Shelf PNGs have no alpha channel; character and book layers retain transparency.
- `layers/` contains individual editable SVG exports. `bookworms-preview.png` shows the complete composition.

Regenerate with Python 3, Node.js, and the `sharp` Node package available:

```sh
python3 scripts/generate-app-icon.py
```

The script accepts `--node /path/to/node`; `NODE_PATH` can point to an existing Node package directory. It validates output dimensions, color profiles, and transparency during generation.

## tvOS preparation

- Landscape 5:3 artwork: 1280 × 768 source dimensions with an 800 × 480 viewBox. Apple's current Human Interface Guidelines list an 800 × 480 tvOS layout.
- Three named, editable groups: opaque full-bleed background, worms, and foreground book. The generator exports these into the corresponding Xcode image stack layers.
- No baked-in rounded-corner mask. tvOS applies the final shape.
- Main artwork is centered, with generous side space and roughly 70 points below / 90 points above it in the viewBox. These are design margins, not an Apple-defined universal safe zone. Actual clipping and parallax must be checked in Xcode and on Apple TV after asset generation.
- Packaging uses the tvOS asset catalog image stack. The current app targets tvOS 26.

Check foreground cropping and parallax on Apple TV after regenerating the assets.

## References

- [Apple: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple: Images — tvOS layered images](https://developer.apple.com/design/human-interface-guidelines/images)
- [Apple: Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
