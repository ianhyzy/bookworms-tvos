# Book Wall models, animation, and local spines

Book Wall generates spine artwork on Apple TV. It does not call an AI service or download fonts. It may use the existing artwork store to fetch the selected cover before sampling that image locally. A book without a usable cover still gets a deterministic, readable spine. A book whose cover URL produced no image is downloaded again 30 seconds after preparation, as on the shelf; if the cover arrives, the book's spine, casing, and cover artwork change in place without another fall, and its slot keeps the proportions it was laid out with.

This document describes the implemented behavior and the constraints to preserve when changing it. See the [development handoff](handoffs/2026-09-29-book-wall.md) for work in progress and evidence locations, and [Book Wall checks](TESTING.md#book-wall-checks) for device verification.

## Implementation map

| File | Responsibility |
| --- | --- |
| [BookWallLayout.swift](../Bookworms/Models/BookWallLayout.swift) | Book proportions, text-driven minimum sizes, column spacing, stack thickness, and covering allowance. |
| [BookWallPreparation.swift](../Bookworms/Services/BookWallPreparation.swift) | Prefetch artwork, derive layout, rasterize textures, and build reusable model entities before presentation. |
| [BookWallLocalSpine.swift](../Bookworms/Models/BookWallLocalSpine.swift) | Genre fonts, sampled colors, and spine contrast. |
| [BookWallHardcoverMesh.swift](../Bookworms/Models/BookWallHardcoverMesh.swift) | Continuous casing and shaped artwork meshes, corner profiles, bevel normals, and UV coordinates. |
| [BookWallScene.swift](../Bookworms/Views/BookWallScene.swift) | Model assembly in `makeBook`, texture helpers, physics, camera, lights, projection, flight planning, and the shared motion clock. |
| [BookWallView.swift](../Bookworms/Views/BookWallView.swift) | Native focus controls, transition tasks and revision guards, detail presentation, coordinate conversion, and the canvas bridge. |
| [BookWallRenderHost.swift](../Bookworms/Views/BookWallRenderHost.swift) | Launch-only host configuration and the shared event, projection, and ambient-light adapter contract. |
| [BookWallRendererHost.swift](../Bookworms/Views/BookWallRendererHost.swift) | Opt-in `RealityRenderer` host, explicit render textures, display-link updates, and Metal presentation. |
| [ShelfView.swift](../Bookworms/Views/ShelfView.swift), [BookDetailView.swift](../Bookworms/Views/BookDetailView.swift) | Scene lifetime, preparation trigger, full-screen background, detail-column geometry, and Back overlay. |

## Genre and typeface

The app checks the book's ranked genre tags and uses the first recognized category. Each category has a typeface included in tvOS 26 and 27; an unavailable face falls back to the system semibold font.

| Category | Typeface |
| --- | --- |
| Fantasy and LitRPG | Georgia Bold |
| Science fiction | Futura Bold |
| Mystery, thriller, and crime | DIN Condensed Bold |
| Horror and gothic | Impact |
| Romance | Avenir Heavy |
| History and historical fiction | Times New Roman Bold |
| Literary fiction and classics | Avenir Next Demi Bold |
| Biography and memoir | Helvetica Neue Bold |
| Young adult and middle grade | Arial Rounded Bold |
| Graphic novels and comics | Arial Bold |
| Poetry and verse | Verdana Bold |
| Humor and satire | Courier New Bold |

Unrecognized or missing genres use Avenir Next Demi Bold. The selected face applies to both the title and author. The renderer measures words and draws each fitted line, then sizes the texture to the visible spine plane so letters keep their proportions. The title stays at or above 56 texture pixels and the author at or above 48. Below a 5% top margin, the title takes 58% of the spine's thickness and the author the next 32% (`titleTop`, `titleShare`, `authorShare`). Each grows to the largest size that fits its area, so thick spines get large lettering. The book's dimensions account for the words and line count before the spine texture is drawn.

## Cover palette and contrast

The app reduces the selected cover to a 32 × 32 RGB sample and groups colors into coarse color bins. The most common bin supplies the spine color. A contrasting sampled color supplies the text when it reaches at least **4.5:1** against the spine; otherwise the app chooses whichever of black or white gives stronger contrast. A second contrasting cover color supplies the decorative lines when available; they draw at 40% opacity so the lettering leads. The title and author use the same full-opacity text color, so both meet the same contrast threshold. When cover pixels are unavailable, the app uses the existing deterministic local background and a contrast-safe text color.

Cover sampling and font choice run locally. A newer library snapshot or cover cannot be overwritten by a stale artwork result. The scene keeps its generated spines when a reader returns from book details.

## Book shape

`bookHeight` means the head-to-tail height of an upright book. It runs left to right in Book Wall because the books lie on their sides. `coverWidth` runs from spine to fore edge; `spineThickness` includes the boards and page block and runs up and down in a settled stack. Collision shapes and stack spacing also include the thin covering outside each board. Page count grows the book's height and thickness. The front-board width follows the selected cover's width-to-height ratio, so its area also grows with page count. The book height has a minimum of 2.75 scene units, and the page-count scale has a floor of 1.15, so short books stay close in size to long ones. Each book is at least 6 times as long as it is thick (`minimumLengthToThickness`), so thick books do not read as blocks. Page count adds thickness up to 1.3 units (`maximumPageThickness`) before per-book variety, so long books look substantially thicker. Length stops at 5.6 units (`maximumBookLength`), so a very thick book reads as chunky instead of widening its column enough to shrink the wall. Size tracks page count only loosely: per-book seeds scale thickness up by as much as 25% and length by as much as 22%, so similar books still differ and few rest exactly on the minimums. When no usable cover ratio is available, the board uses a 2:3 ratio.

Each model has a light paper block inside one continuous hardcover casing. The front, spine, and back join along the same outer profile without an inset spine shoulder. The boards extend beyond the pages at the head, tail, and fore edge, following [Library of Congress bookbinding guidance](https://www.loc.gov/preservation/care/PDF/intermed_treat2.pdf). The boards have nearly square corners, with less rounding at the spine than at the fore edge. Straight spine ends meet the covers through crisp folds, and the spine wall reaches the page block independently of the corner radius. A shallow bevel around each face catches a narrow highlight as the book turns. Its width and depth are independent of the outer corner radii, so the edge remains visible at the scene's 1080p resolution while the silhouette stays nearly square. The front artwork follows that bevel. The preferred cover fits the upper covering without changing its aspect ratio and uses a satin material that produces a soft highlight as the book turns under scene light. A synthesized margin, sized at 0.3% of each texture dimension, repeats each actual image edge and blends into the case color; no gradient covers source pixels, including lettering printed at the edge. The connected casing gives that transition a physical edge. The generated spine sits on the spine wall as an opaque plane: its texture draws the lettering and decorative lines over the case color, and its material shares the case's surface settings, so it shades like the case around it and the label has no edge. The lettering is drawn 10% brighter than its style color because lit lettering reads dimmer than the former unlit lettering. A transparent hinge decal 0.085 units from the spine shades the front board's joint with a soft groove and a faint highlight on the fore-edge side.

Every book falls with a dynamic physics body onto a visible shelf with a static collision shape. Flat covers, zero restitution, and continuous collision detection keep the contact geometry aligned and prevent fast books from passing through a support between frames. At a supported landing, the scene clears the book's velocity and switches it to kinematic mode so later impacts do not launch it again. Continuous collision detection is enabled only while a body is dynamic; PhysX logs an error on every update for a static or kinematic body that keeps it, which costs main-thread time. Contacts remain eligible when two falling books touch before the lower one lands. Spine focus targets appear at each book's planned resting position in the tab's first render, computed from the layout and viewport without the renderer; opening a book waits until every book has reached support. The scene has no invisible lane or front and back collision walls. The layout uses about one column per 10 books, from three to five columns, so stacks grow tall rather than wide. Books keep their spines flush on one front plane; centered books of different depths would put deeper spines nearer the camera, where perspective lets them hide part of the book above or below. When the fall settles, each book is seated at its computed stack height. A crowded column gives up only thickness beyond what each spine's lettering needs. Each column is as wide as its own longest book plus 0.24 units of clearance (at least 3.1), so one long book widens only its column. The camera frames the settled stacks and the header area above them; books start above the frame and fall into view. Stacks can reach 8.5 units above a floor at -4.5, and spines are at least 0.55 thick so the enlarged lettering fits. **Drop again** at the top right reuses the prepared models and restarts the fall. Reduce Motion places the books immediately. See [Book Wall in the view guide](../VIEWS.md).

## Framing and selection movement

The RealityKit canvas fills the screen behind the native `TabView`. The Book Wall tab supplies focus buttons and detail text without a separate background or a smaller render viewport. Projection uses the canvas bounds; focus targets and detail rectangles convert between the canvas and tab origins. The camera fits the complete drop envelope, settled books, and focus lift with space at the screen edges. Book dimensions and cover aspect ratios stay unchanged.

The 3D canvas renders at a maximum of 1920 × 1080 pixels, including on 4K displays.
It still fills the screen and shows the complete scene. Generated spine text and
cover art share this render resolution, so small lettering and fine image detail
can appear softer when enlarged on a 4K display. Source textures retain their
prepared resolution. Native menus, labels, and detail text use the display's
normal resolution. The cap also applies while the selected book floats in detail.

Focus slides a settled book 0.35 scene units (`focusPullOut`) straight toward the viewer without turning it, exposing its page edges; a soft shadow plane (`showContactShadow`) darkens the top of the spine below it, where the top light would cast the book's shadow, and fades in with the pull-out. Highlights based on brightening a case failed on light-colored books and point lights cannot isolate one spine, so focus relies on position and shadow.

A red bookmark ribbon, 0.28 units wide, hangs from under the focused book, 30% of the way along its spine, with a fixed visible length of 1.05 units (five 0.21-unit segments). It sits just behind the pulled-out spine and in front of the lower spines and shelf lip. It is a chain of pooled segments with a swallowtail tail; focus changes only reposition them. On arrival it waits for the book's 0.2-second pull-out, because it hangs at the pulled-out depth and would otherwise show in front of the still-seated book. It then slides out of the book's underside tail first over 0.55 seconds, with a wave traveling down its length. Only the length below the book's bottom edge is drawn; the emerging segment shortens to fit, so the ribbon never relies on the moving book to hide it. The wave damps out within half a second of the ribbon hanging free. RealityKit has no cloth simulation, so `poseRibbon` computes the motion analytically on a scene-update subscription that ends when it settles. Moving focus removes it at once. It stays through selection and return without animating again, hiding with the wall while details are open. Reduce Motion shows it at rest. Selecting a book starts a 1.8-second flight. The book moves straight out until its complete rotating bounds clear the deepest neighboring cover. It then moves toward the detail column and turns toward the camera. The path preserves velocity at the clearance point and eases into the destination.

The camera moves back during extraction to keep the entire book visible. Planning checks the book's outer corners along the paired camera and book path against the visible screen area. One RealityKit scene-update subscription advances both transforms from the same elapsed time. Book Wall details reserve 32% of the content width for the model; ordinary cover details use 24%. The model is centered vertically on the screen and horizontally by its projected neutral silhouette. The Back overlay covers only its navigation area. The detail pose fits a volume containing the complete yaw sweep and every combination of horizontal and vertical drift inside its column. The same envelope, including the return's initial velocity, is reserved along the path back to the wall. The central pose turns the spine toward the viewer by 0.44 radians (about 25°) beyond facing the camera and tips the head forward by 0.09 radians (about 5°) about the book's own horizontal axis, so the spine, casing, and head page edges show beside the cover. A face-on pose hides that depth and reads as a flat card.

The same model remains mounted when detail text appears over the wood background. A key light, fixed in the world above, right, and in front of the detail pose, fades up during opening while the fill and the shelf lights dim. The book flies into its light, and a soft drop shadow (`updateDetailShadow`) darkens the wall behind it, down and to the left. The return reverses the fade. In detail, it drifts up to 24 screen points vertically over a 40-second cycle and 6 points horizontally over a 48-second cycle. An independent 60-second yaw cycle turns it 2° each way from its central pose. Idle movement eases in over four seconds from the flight's final pose. **Back to view** and the remote's Back button fade the detail text out, then start a 1.8-second return. The return begins at the current idle pose and retains its translational and angular velocity while blending out the offset, reverses the camera and book path, and retains the original focused pose without a final reset. Reduce Motion places books and changes detail poses directly, without falling, flight, or idle motion.

The selected spine remains mounted during opening; other spines and **Drop again** cannot start another transition. The invisible spine targets leave and return without a transition, because animating their removal inside the detail fade kept the main thread busy and delayed the wall's frames. Detail text appears only after a successful flight. A failed opening restores the wall and offers a retry message. Leaving Book Wall or replacing its prepared books cancels the presentation and restores the settled models. Task revisions prevent an old completion from reopening details. Leaving during a fall places the remaining books on their supports while the wall is hidden, so returning cannot resume overlapping drops.

Settled books remain kinematic. The fall uses gravity and collision contacts, while selection and detail movement follow an authored path. The wall does not continuously simulate a freely moving or knockable stack.

## Model construction reference

`makeBook` assembles four meshes: the page-block root, one continuous casing, an opaque spine-artwork plane, and the shaped front-artwork surface. The casing supplies the back cover; there is no separate back artwork. Pages use a cream material. When the shared page-edge texture is available, planes on the head, tail, and fore edge show fine leaves that darken toward the boards.

### Coordinates and artwork

| Coordinate | Meaning in the settled model |
| --- | --- |
| Local X | Head-to-tail book height, horizontal in the wall. |
| Local Y | Book thickness; the front cover faces +Y. |
| Local Z | Spine-to-foreedge width; the spine faces +Z. |

The casing helper constructs an XY outline with thickness on Z, then rotates both positions and normals to `[x, z, -y]`. Its two bottom outline corners are the spine corners. The artwork mesh uses width = `coverWidth` and height = `bookHeight`; its two left corners become the spine corners after `Ry(π/2) * Rx(-π/2)`. Keep these asymmetric corner profiles synchronized.

Artwork UVs are `U = x / width + 0.5` and `V = y / height + 0.5`. This V orientation matches the existing texture pipeline; flipping it turns the cover upside down. The front artwork sits 0.0005 scene units beyond the outer casing face to avoid coincident surfaces. The spine plane sits at `coverWidth / 2 + 0.009`.

### Geometry and material parameters

All lengths below are scene units unless stated otherwise. `shortSide` is `min(bookHeight, coverWidth)`.

| Parameter | Current value |
| --- | --- |
| Board thickness | `min(0.045, spineThickness * 0.12)` |
| Covering outside each board | `BookWallLayout.coverWrapThickness = 0.006` |
| Foreedge corner radius | `shortSide * 0.005` |
| Spine corner radius | `shortSide * 0.0015` |
| Shallow edge-roll width | `shortSide * 0.005` |
| Edge-roll depth | `min(boardThickness * 0.18, edgeRollWidth)` |
| Page-block size | `[bookHeight - 0.06, spineThickness - 2 * boardThickness - 0.015, coverWidth - 0.07]` |
| Page-block corner radius | `0.008` |
| Inner spine-wall depth | Half the outer-width minus page-width difference; currently `0.035` |
| Roughness: pages / casing / front artwork | `0.85 / 0.56 / 0.52` |
| Front artwork metallic | `0` |
| Collision size | `[bookHeight, spineThickness + 2 * coverWrapThickness, coverWidth]` |

The casing helper receives board thickness including the covering. It also caps roll depth at 25% of that thickness. The corner silhouette, roll width, roll depth, and inner spine-wall depth are independent controls:

- Keep the outer corners nearly square while preserving a shallow highlight wide enough to read at 1080p. A physically present bevel can disappear when it projects to less than one render pixel.
- Use elliptical normals for unequal roll width and depth. The helper uses six intervals per corner and three per edge roll. Inner extents shrink with the inset; inner corner radii clamp to zero when the roll is wider than the outer radius. Omit zero-area triangles instead of creating inverted rings.
- Keep flat cap normals aligned with the face. Split the head/tail outline where the inner spine meets the pages so board and spine side faces do not overlap. Spine endpoints must meet the outer bevel at the same depth.
- Derive inner spine-wall depth from the page inset, not the corner radius. Otherwise sharper corners can open a gap between the casing and paper.
- Preserve the full collision envelope and stack allowance when changing covering thickness. Also update `corners(of:at:)`, extraction clearance, focus projections, and their verification if any part of the visible model extends beyond the current bounds.

Mesh generation has native box/plane fallbacks. A fallback rendering successfully is not proof that the intended casing mesh generated correctly.

### Preparation and texture limits

`BookWallPreparation` starts from the loaded current-year snapshot. It prefetches artwork, computes proportions, and constructs reusable entities before the wall is presented. `BookWallRasterizer` draws on a separate actor; RealityKit texture/entity creation remains on the main actor, with cancellation checks and a yield between books. Focus and frame updates reuse these resources.

The cached cover input requests a maximum pixel size of 400 with additional networking disabled. `BookWallCoverTexture` creates a 512-pixel-wide texture with proportional height; that output size does not add detail absent from the source. It fits source artwork inside the 0.3% margin rather than cropping it. Only synthesized bleed pixels blend into the case color. Spine textures use 420 pixels per world unit on both axes to preserve glyph proportions. These preparation limits are separate from the 1080p scene backing limit.

## Animation maintenance

`flyToDetail` returns success explicitly. `BookWallView.openDetail` must keep the selected focus target mounted and wait for success before revealing native detail text. Failed planning leaves the wall usable. Transition and configuration revisions reject stale task completions.

The flight planner builds 181 paired book/camera poses. During the first 35% of opening, the book translates straight out until its entire rotating bounding volume clears the deepest neighboring cover. Quintic Hermite interpolation carries velocity through that clearance point; the remaining path turns and translates toward detail. The camera dollies back during extraction. `SceneEvents.Update` samples that path using elapsed time over 1.8 seconds; the 181 samples are not a frame-rate target.

The same scene-update subscription drives flight, camera depth, and the light fade, then analytic idle motion. Flight and idle callbacks create no per-frame Tasks or SwiftUI state publications. Preserve this ownership instead of layering a second animation system over the selected entity.

`idleTranslationAmplitude` converts the screen-point drift into world units. `idleMotion` returns both offset and analytic velocity, including the four-second ramp. Capture it before clearing `idlePose` on dismissal. The first 35% of return blends those offsets and velocities into the reversed flight; resetting the entity to the neutral detail pose first causes a visible discontinuity.

Keep these dependencies together when changing motion:

- `detailDestination`, `fitsMotionEnvelope`, `yawRange`, and `returnAllowance` reserve the complete model, independent drift phases, and return velocity. Frustum checks include all eight corners, the near plane, and interior yaw extrema; yaw endpoints alone are insufficient.
- The detail pose has a fixed pitch (`detailPitchRadians`) applied after its yaw; `corners(of:at:)` includes it, so the frustum fit covers it. The current extra angular motion is only world-Y yaw. Adding animated pitch or roll requires extending the swept-volume bound and angular-velocity return correction. A fixed pose tilt is a separate design choice; it must still pass the complete projection fit and physical-TV inspection.
- Preserve physical proportions and use camera distance to fit. Do not hide an invalid path with model scaling, screen-edge clamps, or a smaller clipped viewport.
- Reduced drift can let a height-limited model fit slightly closer to the camera. Compare centering and size as well as motion after changing an amplitude.

## Lighting and presentation maintenance

The scene uses these lighting and presentation elements:

- **Studio environment.** `BookWallPageTexture.makeStudioEnvironment` draws a neutral equirectangular gradient (bright above, darker below, no azimuth) that replaces the view's default image-based light. Its exponent sets the room's fill level. The environment is bright in every direction, so surfaces use `surface(color:roughness:specular:)` with reduced specular reflectance (0.1; 0.25 for cover artwork; 0 for the backdrop). Default reflectance adds a gray haze that lifts dark spines and desaturates colors.
- **Backdrop.** A camera-child plane behind the shelf shows `setBackdrop`'s rendering of `WoodBackground`, which `ShelfView` produces with `ImageRenderer` at one pixel per point whenever the palette or viewport changes. It is a camera child scaled with its distance, so it frames exactly like the SwiftUI background at every camera depth. `placeBackdrops` keeps it 3.5 units behind the shelf (`backdropGap`) while the camera dollies, so move the camera only through `setCameraDepth`. A plane carried into the shelf would sort behind the fading wall, whose depth would then hide the detail image inside the wall's outline. The backdrop is unlit: `bakeWall` bakes the room's lighting into the image instead, because a full-screen lit surface cost more GPU time than the rest of the scene. The resting image scales each color channel by a base level, a warm pool with the falloff of a point light 3.3 units in front of the wall behind the stacks, and a faint wash (`restingWallLight`). A second camera-child plane shows the dimmer, nearly flat detail image (`detailWallTop`, `detailWallBottom`) and fades in with the detail light level. Both are shown without tone mapping. The factors were fitted to Simulator captures of the formerly live-lit wall; the `wall-raw-backdrop` diagnostic shows the unlit image for refitting. The bake reruns only when the image or the framing changes. Because the backdrop fills the frame, the renderer's Metal layer is opaque, with a dark wood clear color that shows only until the backdrop texture arrives. An opaque layer lets tvOS send the wall straight to the display; a transparent one makes the system compositor blend the whole frame on every update. The per-book focus targets over the canvas are fully transparent for the same reason.
- **Shelf light** (`shelfLight`). A warm point light 4.5 units in front of and 1.5 above the stacks' center. Its falloff lights the middle stacks most while the outer stacks stay readable. The environment exponent at rest (`restingAmbientExponent`, 0) keeps the room dim.
- **Pool light** (`poolLight`). A warm point light hidden just behind the shelf. It catches the tops and edges of the upper books; its round glow on the wall is part of the baked backdrop.
- **Detail key light** (`detailLight`). A point light that `placeDetailLight` puts 3.2 units from the detail destination along `detailLightDirection` (`[1.2, 1.8, 5]`, normalized) when a flight is planned; it does not move with the book. The top light brightens from 200 to 400 lux. `setDetailLightLevel` raises both, fades the shelf and pool lights out, and lowers the environment exponent by up to `detailAmbientExponent` (-0.8) on the flight clock. `showOnlyDetailBook` and `configure` keep them in the scene.

The `RealityRenderer` host reuses the scene's entities and motion and controls its output resolution, antialiasing, and dynamic range. It draws only when the scene needs a frame (`BookWallScene.needsFrame`): while books fall, while a flight, the detail drift, the ribbon, or a focus pull-out animates, or after any change made through the scene's public methods. Otherwise it keeps the last frame, so the system compositor can reuse overlays instead of recompositing them on every refresh. A change to scene state outside those methods must call `setNeedsFrame()`, or the screen keeps showing the previous frame. Book Wall details draw **Show more** as a flat platter rather than glass: glass samples the 3D layer behind it, and while the open book drifts, that layer changes every frame. `RealityView` is not used because it renders at native display resolution on tvOS.

Use point and directional lights. `SpotLight` produced no visible light on Apple TV at any tested intensity, cone, or orientation, while a point light at the same position did. Point-light intensity is lumens emitted in every direction and scene units are meters, so illuminance is about lumens / (4π × distance²); lights several units away need hundreds of thousands of lumens.

The same level fades the rest of the wall (other books, shelf and label, ribbon) through `OpacityComponent` over the second half of the opening and back in during the return, so `showOnlyDetailBook` hides already-invisible entities. The pool light finishes fading before the wall turns translucent and returns only once it is opaque again, because it brightly lights the backs of the books. SwiftUI detail text, the Back overlay, and wall controls fade over 0.35 seconds after the book lands, and fade out before the return flight starts, so removing them never stalls a moving book; Reduce Motion switches them directly. The renderer advances motion and physics by at most two refreshes per frame, so a late frame slows an animation briefly instead of skipping it ahead. Idle retains the level; cancellation and `setDetailLightLevel(0)` restore the resting light and full opacity. Reduce Motion applies the endpoint directly. The detail target moves right by 12% of the column width (`detailShadowRoom`) to leave room for the shadow on the left. The SwiftUI wood sample under the Back overlay is multiplied by `detailWallTop`, so it matches the detail wall image.

No light casts a shadow. A dim, steep `DirectionalLight` (`topLight`) adds top light, and soft shadow planes stand in for the shadows it would cast, because each shadow-casting light adds a shadow-map pass and a shadow lookup on every lit pixel. The Simulator renders no RealityKit shadows at all. The camera uses a 30° vertical field of view (`fieldOfView`), similar to a 50mm lens; wider angles made page edges appear to stretch as books moved. Measure detail presentation on the Apple TV when changing light count, shadows, or backdrop resolution.

The shelf is 0.5 units thick so its front face can carry a label. `BookWallShelfLabel` renders each book's title and author, plus a resting hint, during preparation at 128 pixels per unit in the app's font style; `showShelfLabel` swaps the prepared texture onto an unlit plane on the shelf front when focus changes, so remote movement does no text drawing. The front face is parallel to the image plane, so the scene's projection gives the label the shelf's perspective. Labels use the font style saved when preparation ran.

The scene uses full-screen point coordinates independently of the renderer's texture dimensions. Native SwiftUI remains at display resolution. Convert focus and detail rectangles using measured canvas/tab origins; padding compensation is not an equivalent coordinate conversion.

`BookDetailCoverLayout` shares the Book Wall column fraction and 300 × 144-point Back-overlay size with the scene and navigation cover. Keep the fit below that overlay and centered by the projected neutral silhouette. Geometry changes must not obscure native Back navigation or the sidebar.

Leaving the tab, backgrounding, replacing prepared books, or resizing the viewport cancels transitions and restores resting poses, camera depth, visibility, and lighting. The native focus engine still owns directional movement. See [focus and remote navigation](FOCUS_NAVIGATION.md).

## Renderer host

Book Wall renders through `RealityRenderer`. The launch arguments below tune it for diagnosis; they have no Settings interface or persisted preference. See the [renderer results](handoffs/2026-09-30-wall-realityrenderer-results.md) for measurements and verification status.

The host renders the shared `BookWallScene` root, camera, prepared models, physics, baked backdrops, shadow planes, lights, ribbon, labels, and flight planning. `BookWallView` retains native focus controls and detail presentation. The adapter provides scene events, point projection, and ambient-light changes; they do not assign focus. Attachment refreshes focus rectangles for a configured wall, and detachment cancels subscriptions and active transitions. Backdrop baking uses the host's viewport in points.

`BookWallRendererHost` mounts a noninteractive, opaque `CAMetalLayer` surface in the existing `TabView` background. A display link requests 60 Hz and drives `RealityRenderer.updateAndRender` with elapsed frame time. Three frame slots bound queued work while RealityKit finishes one frame as it encodes the next. With every slot busy, a tick skips submission, and the next update advances at most two refreshes.

RealityRenderer renders into each slot's own texture. When the slot's Metal event reports the frame's GPU work finished, a background queue takes a drawable, draws the texture into it (bilinear when the internal size is smaller; MetalFX is not implemented), presents it, and releases the slot when that pass completes. Rendering straight into drawables, and presenting from RealityRenderer's scheduling callback, dropped the fading wall and other later passes on Apple TV during flights; the Simulator did not show it. Holding a drawable from the start of each frame instead held the renderer near 36 fps. Generation checks prevent old completions from changing a recreated host. GPU completion does not prove when a frame reached the display. The presentation shader (`BookWallPresentation.metal`) compiles with the app, so opening the wall compiles no shaders.

The output uses `bgra8Unorm_srgb` with a Display P3 layer color space and `extendedDynamicRangeOutput = false` for standard dynamic range. Display P3 uses the sRGB transfer curve; tagging the layer as sRGB instead desaturates the scene through compositor color conversion. Antialiasing defaults to 4× multisampling; `off` disables it. Backdrop materials bypass tone mapping. The layer allows non-framebuffer operations for RealityKit's output path. The display-link rate is a request, not measured presented performance.

Projection uses the shared camera's vertical field of view and the viewport's point dimensions independently of the texture dimensions. A fatal renderer error pauses its clock, detaches the adapter, and cancels active flights. Leaving Book Wall through the sidebar and returning creates another host.

| Launch argument | Values | Default | Applies to |
| --- | --- | --- | --- |
| `--wall-output=` | `1080` (1920 × 1080), `900` (1600 × 900), `720` (1280 × 720) | `1080` | Renderer output drawable |
| `--wall-internal=` | `1080`, `900`, `720` | `1080`, capped at output size | Renderer internal resolution |
| `--wall-antialiasing=` | `off`, `on` | `on` | Renderer 4× multisampling |
| `--wall-fps=` | `30`, `60` | `60` | Renderer display-link request |

Renderer diagnostics include `wall-no-ibl` (zero environment-lighting weight and no generated studio environment) and `wall-unlit-shelf` (constant unlit shelf tint). These isolate shading cost and change appearance; neither is a fitted lighting replacement. Pipeline windows report submission/completion counts, skipped and idle ticks, occupied slots, callback duration, and layer scale to stderr and Instruments. These counters do not measure displayed frames.

In diagnostic builds, `--isolate=wall-900p` or `wall-720p` selects the renderer's internal resolution unless `--wall-internal` overrides it. The output stays at 1080p. A lower resolution or 30 Hz remains an experiment and requires owner approval before becoming a default.

For Debug Simulator captures, use `--test-scenario=artwork --start-view=bookWall`, then add any renderer arguments. Inspect the `BookWallRendererViewport` log for configured dimensions. Keep Simulator visual comparisons separate from Apple TV frame measurements.

## Verification when making changes

Follow [Book Wall checks](TESTING.md#book-wall-checks) and [performance diagnosis](PERFORMANCE_DIAGNOSIS.md#book-wall-motion). Lint edited Swift files, then use the normal `BookwormsDevice` Release install path. Run automated tests only when requested under [contributor instructions](../AGENTS.md).

For Simulator captures, `DEBUG` Simulator builds accept `--book-wall-entry=ID` to choose the focused book and `--book-wall-open-entry` to open it once the wall settles; launch with `--test-scenario=artwork --start-view=bookWall` and capture with `xcrun simctl io <device> screenshot`. Use them to compare lighting before and after a change, remembering that the Simulator draws no RealityKit shadows.

Keep source checks, physical appearance, manual movement, and frame measurements separate. Screenshots show placement and materials at captured poses; they do not establish smooth motion or the full yaw envelope. Diagnostic scene-update cadence and callback cost are not presented-frame measurements. Store dated logs, captures, source hashes, and verification limits under ignored `.local/` result folders. Check those records against the candidate being evaluated.
