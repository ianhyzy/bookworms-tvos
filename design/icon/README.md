# Bookworms icon

[`bookworms.py`](bookworms.py) is the editable source: a Blender script that models two pink worms reading over an open purple book and renders them as flat-colored layers. The worms have smooth outlines and round heads. The smiles, the book's center line, the book's edges, and the eyes waver slightly, like a pen drawing. Each worm looks at the page across from it, and both of its pupils shift by the same amount, so the eyes never cross.

[`bookworms.svg`](bookworms.svg) is the flat logo that the model follows. No asset is generated from it.

## Rendered layers

Run Blender 5 from the repository root:

```sh
blender -b -P design/icon/bookworms.py
```

It writes three images with transparent backgrounds into `layers/`:

- `tv-book.png` and `tv-worms.png`, 1280 × 768: the Apple TV icon's front and middle layers. The book runs past the bottom and both sides of the frame, so parallax never shows one of its edges.
- `shelf.png`, 4640 × 1440: the worms and the book in one image for the Top Shelf fallback, with a wider book.

For the iPhone and Mac icon, pass a folder, such as the `ios` repository's `Bookworms/AppIcon.icon/Assets`:

```sh
blender -b -P design/icon/bookworms.py -- --square path/to/Assets
```

It writes `book.png`, `face.png` (the pupils and smiles), `eyes.png` (the eye whites), and `worms.png` at 1024 × 1024, which are the four layers of that Icon Composer icon.

## Generated assets

The app uses `Bookworms/Assets.xcassets/App Icon & Top Shelf Image.brandassets`, selected by `ASSETCATALOG_COMPILER_APPICON_NAME` in both the Xcode project and `project.yml`.

- Home Screen: 400 × 240 and 800 × 480 PNGs, each with three layers.
- App Store: 1280 × 768 PNGs with the same three layers.
- Layer order, front to back: purple book, pink worms, cream background. The background is the cream gradient of the iPhone and Mac icon, `#FCF3E0` to `#EFE0C2`.
- Standard and wide static Top Shelf fallbacks: 1920 × 720 and 2320 × 720, plus their 2× variants. The standard image is the middle of the wide one, so the worms are centered in both. The dynamic Top Shelf extension continues to provide selected books.
- Each PNG includes an sRGB profile. Background and Top Shelf PNGs have no alpha channel; the worm and book layers keep their transparency.
- `bookworms-preview.png` shows the three layers together.

Regenerate them from the rendered layers with [uv](https://docs.astral.sh/uv/), which supplies Pillow:

```sh
uv run scripts/generate-app-icon.py
```

Add `--local` for the device-install icon, which draws a LOCAL badge on the book's cover and writes `Local App Icon.brandassets` and `bookworms-local-preview.png`. The script stops if a layer that should be transparent is opaque.

## tvOS preparation

- Landscape 5:3 artwork at 1280 × 768. Apple's current Human Interface Guidelines list an 800 × 480 tvOS layout.
- No baked-in rounded-corner mask. tvOS applies the final shape.
- The tvOS icon is a layered image stack, which Icon Composer doesn't produce: the system adds parallax and a focus shine, but no Liquid Glass and no shadows between layers.
- Packaging uses the tvOS asset catalog image stack. The current app targets tvOS 26.

Check foreground cropping and parallax on Apple TV after regenerating the assets.

## References

- [Apple: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple: Images — tvOS layered images](https://developer.apple.com/design/human-interface-guidelines/images)
- [Apple: Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
