"""Models the Bookworms icon in Blender and renders its layers: two worms reading over an open book.

Run from the repository root:

    blender -b -P design/icon/bookworms.py                  # Apple TV layers, into design/icon/layers
    blender -b -P design/icon/bookworms.py -- --square DIR  # iPhone and Mac layers, into DIR

Every layer has a transparent background and is complete: the layers in front cut nothing out of it.
"""
import bpy, bmesh, math, os, sys
from mathutils import Vector, noise

HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
SQUARE = args[args.index("--square") + 1] if "--square" in args else None

PINK, CREAM, PURPLE, PLUM = "#F08FA6", "#F7EEDB", "#9874BC", "#50344D"
# How unsteady the drawn lines and edges are: 0 is ruler-straight, and about 1 looks drawn by hand.
WOBBLE = 0.3
# Diffuse brightness where a color's shade starts and ends, and how dark the shade is.
SHADE = (0.15, 1.6, 0.8)

# Each framing: book half-width and height, how far each half folds back in degrees, how far the
# book sits below its square-icon place, how far each worm moves outward, the camera's width in
# scene units, the image size, and the layers to write with the object groups each one holds.
FRAMINGS = {
    "square": dict(book=(2.2, 1.45), fold=20, drop=0, spread=0, width=2.75, size=(1024, 1024),
                   layers={"worms": {"worms"}, "eyes": {"eyes"}, "face": {"face"}, "book": {"book"}}),
    # The landscape framings lay the book flatter and lower so that it doesn't dominate, and run it
    # past the bottom and both sides, so that the frame crops it and its own edges stay out of view.
    "tv": dict(book=(3.0, 2.0), fold=9, drop=0.16, spread=0.09, width=4.6, size=(1280, 768),
               layers={"tv-worms": {"worms", "eyes", "face"}, "tv-book": {"book"}}),
    "shelf": dict(book=(5.8, 2.0), fold=9, drop=0.16, spread=0.09, width=8.9, size=(4640, 1440),
                  layers={"shelf": {"worms", "eyes", "face", "book"}}),
}

# The direction from the scene toward the orthographic camera, which looks slightly down.
VIEWER = Vector((0, -math.cos(math.radians(10)), math.sin(math.radians(10))))

_seed = [0.0]


def seed():
    """A new offset into the noise field, so that each shape wavers its own way."""
    _seed[0] += 7.31
    return Vector((_seed[0], _seed[0] * 1.7, -_seed[0]))


def wob(p, freq, offset):
    return noise.noise_vector(Vector(p) * freq + offset)


def lin(hexs):
    h = hexs.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c] + [1]


def material(name, hexs):
    """A flat color with one soft shade tone and no highlights; the system adds the glass."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    col = lin(hexs)
    diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
    diff.inputs["Color"].default_value = (1, 1, 1, 1)
    rgb = nt.nodes.new("ShaderNodeShaderToRGB")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].position = SHADE[0]
    ramp.color_ramp.elements[0].color = [c * SHADE[2] for c in col[:3]] + [1]
    ramp.color_ramp.elements[1].position = SHADE[1]
    ramp.color_ramp.elements[1].color = col
    emit = nt.nodes.new("ShaderNodeEmission")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    for a, b in ((diff, rgb), (rgb, ramp), (ramp, emit), (emit, out)):
        nt.links.new(a.outputs[0], b.inputs[0])
    return m


def link(obj, mat=None, parent=None):
    bpy.context.scene.collection.objects.link(obj)
    if mat:
        obj.data.materials.append(mat)
    if parent:
        obj.parent = parent
    return obj


def smooth(obj):
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj


def box(name, center, dims, mat, parent):
    """A slab whose outline wavers in the plane of its two long sides, so that its faces stay flat."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    for v in bm.verts:
        v.co = Vector(center) + Vector((v.co.x * dims[0], v.co.y * dims[1], v.co.z * dims[2]))
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=8, use_grid_fill=True)
    thin, o = min(range(3), key=lambda i: dims[i]), seed()
    for v in bm.verts:
        d = wob(v.co, 1.6, o) * (0.022 * WOBBLE)
        d[thin] = 0
        v.co += d
    bm.to_mesh(me)
    bm.free()
    ob = smooth(link(bpy.data.objects.new(name, me), mat, parent))
    mod = ob.modifiers.new("bevel", "BEVEL")
    mod.width = min(0.04, min(dims) * 0.45)
    mod.segments = 4
    return ob


def sphere(name, center, r, mat):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=r)
    o = seed()
    for v in bm.verts:
        v.co *= 1 + 0.07 * WOBBLE * noise.noise(v.co.normalized() * 1.2 + o)
    bm.to_mesh(me)
    bm.free()
    ob = smooth(link(bpy.data.objects.new(name, me), mat))
    ob.location = center
    return ob


def spline_path(pts, count):
    """Catmull-Rom through pts, resampled to count points evenly spaced by arc length."""
    pts = [Vector(p) for p in pts]
    P = [pts[0] * 2 - pts[1]] + pts + [pts[-1] * 2 - pts[-2]]
    dense = []
    for i in range(len(pts) - 1):
        p0, p1, p2, p3 = P[i:i + 4]
        for k in range(40):
            t = k / 40
            dense.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                                + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    dense.append(pts[-1])
    cum = [0.0]
    for a, b in zip(dense, dense[1:]):
        cum.append(cum[-1] + (b - a).length)
    out, j = [], 0
    for i in range(count):
        s = cum[-1] * i / (count - 1)
        while j < len(cum) - 2 and cum[j + 1] < s:
            j += 1
        f = (s - cum[j]) / max(cum[j + 1] - cum[j], 1e-9)
        out.append(dense[j].lerp(dense[j + 1], f))
    return out, cum[-1]


def ink_line(name, pts, radius, mat, parent=None, taper=0.5):
    """A stroke through pts that wavers, varies in width, and thins to taper at its ends, like a pen line."""
    N = 48
    path, _ = spline_path(pts, N)
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = radius
    cu.bevel_resolution = 4
    cu.use_fill_caps = True
    sp = cu.splines.new("POLY")
    sp.points.add(N - 1)
    o = seed()
    press = min(1, WOBBLE * 2)  # how much of the taper applies, as a pen lifts
    for i, p in enumerate(path):
        t = i / (N - 1)
        sp.points[i].co = (*(p + wob((t * 2.5, 0, 0), 1, o) * (radius * 1.1 * WOBBLE)), 1)
        end = taper + (1 - taper) * math.sin(math.pi * t) ** 0.6
        sp.points[i].radius = (1 + 0.4 * WOBBLE * noise.noise(Vector((t * 4, 5, 0)) + o)) * (1 - press + press * end)
    return link(bpy.data.objects.new(name, cu), mat, parent)


def worm(name, pts, R, mats, look_at):
    """A smooth tube of radius R along pts that ends in a dome, with a face toward the viewer (-Y).

    The outline doesn't waver: a head must read as round. Both pupils take the same offset toward
    look_at, so the eyes never cross.
    """
    RINGS, SIDES = 200, 48
    path, L = spline_path(pts, RINGS)
    tangents = [(path[min(i + 1, RINGS - 1)] - path[max(i - 1, 0)]).normalized() for i in range(RINGS)]
    n = tangents[0].orthogonal().normalized()
    bm = bmesh.new()
    rings = []
    for i, (p, t) in enumerate(zip(path, tangents)):
        n = (n - t * n.dot(t)).normalized()  # parallel transport keeps the tube from twisting
        b = t.cross(n)
        from_tip = min(1, L * (1 - i / (RINGS - 1)) / R)
        r = max(R * math.sqrt(1 - (1 - from_tip) ** 2), 1e-4)
        rings.append([bm.verts.new(p + (n * math.cos(a) + b * math.sin(a)) * r)
                      for a in (2 * math.pi * k / SIDES for k in range(SIDES))])
    for r0, r1 in zip(rings, rings[1:]):
        for k in range(SIDES):
            bm.faces.new((r0[k], r0[(k + 1) % SIDES], r1[(k + 1) % SIDES], r1[k]))
    # The tail end stays open: it starts behind the book, which hides it in every framing.
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    smooth(link(bpy.data.objects.new(name, me), mats["worm"]))

    # The head is a capsule: a sphere of radius R at C that continues down the body.
    idx = round((RINGS - 1) * (1 - R / L))
    C, T = path[idx], tangents[idx]
    F = Vector((0, -1, 0.1)).normalized()
    U = Vector((0, 0, 1))
    U = (U - F * U.dot(F)).normalized()
    S = F.cross(U)

    def surface(d):
        d = d.normalized()
        a = d.dot(T)
        return C + d * (R if a >= 0 else R / max((d - T * a).length, 0.2))

    re = 0.36 * R
    gaze = (F * 0.5 + (Vector(look_at) - C).normalized() * 0.5).normalized()
    for sgn in (-1, 1):
        e = C + (surface(F + S * (0.5 * sgn) + U * 0.2) - C) * 0.84
        sphere(f"{name}.eye", e, re, mats["eye"])
        # A pupil is mostly inside its eye. Moving it toward the orthographic camera puts all of it
        # in front of the eye without moving it in the image.
        sphere(f"{name}.pupil", e + gaze * re * 0.74 + VIEWER * re * 2, re * 0.36, mats["pupil"])
    smile = [C + (surface(F + S * a + U * (-0.5 + 1.6 * a * a)) - C) * 1.01
             for a in (-0.3 + 0.6 * i / 24 for i in range(25))]
    ink_line(f"{name}.smile", smile, 0.045 * R, mats["line"])


def book(w, h, fold, mats):
    """An open book. Local X runs across the pages, Y along the spine, and +Z out of the pages."""
    tc, tp, margin = 0.08, 0.22, 0.08  # cover and page thickness, and the cover's rim around the pages
    root = link(bpy.data.objects.new("book", None))
    for sgn in (1, -1):
        half = link(bpy.data.objects.new("book.half", None), parent=root)
        half.rotation_euler = (0, -sgn * math.radians(fold), 0)
        box("book.cover", (sgn * w / 2, 0, -tc / 2), (w, h, tc), mats["cover"], half)
        pw = w - margin
        box("book.pages", (sgn * pw / 2, 0, tp / 2), (pw, h - margin * 1.75, tp), mats["page"], half)
    box("book.spine", (0, 0, -tc / 2), (tc * 2.2, h, tc), mats["cover"], root)
    z = -tc - 0.004  # the flat logo's center line, as wide as the smiles
    ink_line("book.crease", [(0, -h / 2 + 0.02, z), (0, 0, z), (0, h / 2 - 0.02, z)], 0.024, mats["line"], root, 0.75)
    return root


def light(loc, power, size, color=(1, 1, 1)):
    d = bpy.data.lights.new("light", "AREA")
    d.energy, d.size, d.color = power, size, color
    ob = link(bpy.data.objects.new("light", d))
    ob.location = loc
    ob.rotation_euler = (-Vector(loc)).to_track_quat("-Z", "Y").to_euler()


def group_of(ob):
    """Which part of the icon an object belongs to, for sorting it into a layer."""
    for key, group in ((".eye", "eyes"), (".pupil", "face"), (".smile", "face"), ("worm", "worms")):
        if key in ob.name:
            return group
    return "book"


def render(framing, folder):
    """Builds the scene for one framing and writes its layers into folder."""
    f = FRAMINGS[framing]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _seed[0] = 0.0
    scene = bpy.context.scene
    mats = {"worm": material("worm", PINK), "cover": material("cover", PURPLE), "page": material("page", CREAM),
            "eye": material("eye", "#FFFAEF"), "pupil": material("pupil", "#0A0608"), "line": material("line", PLUM)}

    # The book stands like one on a lectern that faces the worms behind it: its cover faces the
    # viewer, and its top edge leans toward the viewer. Extra height hangs below that top edge.
    w, h = f["book"]
    b = book(w, h, f["fold"], mats)
    grow = (h - 1.45) / 2
    b.location = (0, -0.62 + grow * 0.375, -1.0 - grow * 0.927 - f["drop"])
    b.rotation_euler = (math.radians(-68), 0, 0)
    # Each worm rises from behind the book and reads the page across from it.
    left = [(x - f["spread"], y, z) for x, y, z in
            [(-0.72, 0.9, -1.3), (-0.75, 0.42, -0.6), (-0.76, 0.12, 0.05), (-0.74, 0.06, 0.82)]]
    worm("worm.L", left, 0.54, mats, (0.6, -0.6, -1.7))
    worm("worm.R", [(-x, y, z) for x, y, z in left], 0.54, mats, (-0.6, -0.6, -1.7))

    cam = link(bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera")))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = f["width"]
    cam.location = Vector((0, 0, -0.18)) + VIEWER * 12
    cam.rotation_euler = (-VIEWER).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    light((-4, -6, 6), 1500, 6)
    light((5, -5, 2), 500, 8, (1.0, 0.93, 0.9))
    light((0, 5, 6), 900, 5, (0.95, 0.9, 1.0))
    light((0, -8, -3), 300, 10)

    r = scene.render
    r.resolution_x, r.resolution_y = f["size"]
    r.film_transparent = True
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGBA"
    r.dither_intensity = 0  # flat color compresses far better without dither noise
    scene.view_settings.view_transform = "Standard"  # keeps the palette as authored
    try:
        r.engine = "BLENDER_EEVEE"
    except TypeError:
        r.engine = "BLENDER_EEVEE_NEXT"
    for layer, groups in f["layers"].items():
        for ob in scene.objects:
            ob.hide_render = ob.type not in {"LIGHT", "EMPTY"} and group_of(ob) not in groups
        r.filepath = os.path.join(folder, f"{layer}.png")
        bpy.ops.render.render(write_still=True)


if SQUARE:
    render("square", os.path.abspath(SQUARE))
else:
    for framing in ("tv", "shelf"):
        render(framing, os.path.join(HERE, "layers"))
