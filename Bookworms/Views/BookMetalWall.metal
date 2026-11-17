#include <metal_stdlib>
using namespace metal;

// Draws Book Wall's books with lighting fixed in the shader. Every book is one draw call: each
// vertex names its surface in `part`, and the fragment stage picks that surface's color or
// texture. Keep the structs in step with `BookMetalFrame` and `BookMetalBook` in
// BookMetalWall.swift.

struct Frame {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 shelfLightPosition;
    float4 shelfLightColor;
    float4 poolLightPosition;
    float4 poolLightColor;
    float4 topLightDirection;
    float4 topLightColor;
    float4 ambientTop;
    float4 ambientBottom;
    float4 detailLightPosition;
    float4 detailLightColor;
};

struct Book {
    float4x4 model;
    float4 cloth;
    float4 paper;
    float4 accent;
    float4 lettering;
    // x: the hinge's middle across the front artwork; y: its half width; both zero for none.
    float4 hinge;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
    float part [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float part [[flat]];
};

vertex VertexOut bookVertex(
    VertexIn in [[stage_in]], constant Frame &frame [[buffer(1)]],
    constant Book &book [[buffer(2)]]) {
    VertexOut out;
    float4 world = book.model * float4(in.position, 1);
    out.position = frame.viewProjection * world;
    out.world = world.xyz;
    // Books are never scaled, so the model's rotation also turns normals.
    out.normal = (book.model * float4(in.normal, 0)).xyz;
    out.uv = in.uv;
    out.part = in.part;
    return out;
}

fragment float4 bookFragment(
    VertexOut in [[stage_in]], constant Frame &frame [[buffer(1)]],
    constant Book &book [[buffer(2)]], texture2d<float> spine [[texture(0)]],
    texture2d<float> cover [[texture(1)]], texture2d<float> pageEdge [[texture(2)]]) {
    constexpr sampler trilinear(
        coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear,
        max_anisotropy(4));
    // Mesh coordinates run up the image; texture rows run down it.
    float2 uv = float2(in.uv.x, 1 - in.uv.y);
    int part = int(in.part + 0.5);
    float3 albedo = book.cloth.rgb;
    float gloss = 0.03;
    if (part == 1) {
        albedo = spine.sample(trilinear, uv).rgb;
    } else if (part == 2) {
        albedo = cover.sample(trilinear, uv).rgb;
        gloss = 0.08;
        // The joint beside the spine: a soft groove with a faint highlight on its fore-edge side.
        if (book.hinge.y > 0) {
            float offset = (in.uv.x - book.hinge.x) / book.hinge.y;
            float groove = saturate(1 - abs(offset));
            albedo *= 1 - 0.3 * groove * groove;
            albedo += 0.03 * saturate(1 - abs(offset - 0.8) * 2.5);
        }
    } else if (part == 3) {
        albedo = book.paper.rgb * pageEdge.sample(trilinear, uv).rgb;
    } else if (part == 4) {
        albedo = book.accent.rgb;
    } else if (part == 5) {
        albedo = book.lettering.rgb;
    }

    float3 normal = normalize(in.normal);
    float3 view = normalize(frame.cameraPosition.xyz - in.world);
    float3 light = mix(frame.ambientBottom.rgb, frame.ambientTop.rgb, normal.y * 0.5 + 0.5);
    float3 shine = float3(0);

    float3 toShelfLight = normalize(frame.shelfLightPosition.xyz - in.world);
    light += frame.shelfLightColor.rgb * saturate(dot(normal, toShelfLight));
    shine += frame.shelfLightColor.rgb
        * pow(saturate(dot(normal, normalize(toShelfLight + view))), 24);

    float3 toTopLight = frame.topLightDirection.xyz;
    light += frame.topLightColor.rgb * saturate(dot(normal, toTopLight));
    shine += frame.topLightColor.rgb
        * pow(saturate(dot(normal, normalize(toTopLight + view))), 24);

    // The pool light sits close behind the stacks, so its light falls off with distance.
    float3 toPool = frame.poolLightPosition.xyz - in.world;
    float poolDistance = length(toPool);
    light += frame.poolLightColor.rgb * saturate(dot(normal, toPool / poolDistance))
        / (1 + poolDistance * poolDistance);

    // The detail key light stands 3.2 units from the open book, where its color is its level.
    float3 toDetail = frame.detailLightPosition.xyz - in.world;
    float detailDistance = max(length(toDetail), 0.5);
    float3 detailLight = frame.detailLightColor.rgb * min(4.0, 10.24 / (detailDistance * detailDistance));
    light += detailLight * saturate(dot(normal, toDetail / detailDistance));
    shine += detailLight
        * pow(saturate(dot(normal, normalize(toDetail / detailDistance + view))), 24);

    return float4(albedo * light + gloss * shine, 1);
}

// The wall image behind the shelf, with its lighting already baked in. Drawn again over the
// wall at partial opacity, it fades the wall out.

struct BackdropOut {
    float4 position [[position]];
    float2 uv;
};

vertex BackdropOut bookBackdropVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    const float2 coordinates[] = { float2(0, 1), float2(2, 1), float2(0, -1) };
    BackdropOut out;
    out.position = float4(positions[vertexID], 1, 1);
    out.uv = coordinates[vertexID];
    return out;
}

// `mix.x` crossfades the resting wall image toward the detail one, and `mix.y` is the opacity.
fragment float4 bookBackdropFragment(
    BackdropOut in [[stage_in]], texture2d<float> wall [[texture(0)]],
    texture2d<float> detailWall [[texture(1)]], constant float4 &mix [[buffer(3)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 resting = wall.sample(linearSampler, in.uv).rgb;
    float3 detail = detailWall.sample(linearSampler, in.uv).rgb;
    return float4(resting + (detail - resting) * mix.x, mix.y);
}

// Flat extras: the shelf label, the bookmark ribbon, and soft shadows. Each is a unit square
// placed by `model`, with a premultiplied texture scaled by `tint`, whose alpha is its opacity.

struct Decal {
    float4x4 model;
    float4 tint;
};

struct DecalOut {
    float4 position [[position]];
    float2 uv;
};

vertex DecalOut bookDecalVertex(
    uint vertexID [[vertex_id]], constant Frame &frame [[buffer(1)]],
    constant Decal &decal [[buffer(3)]]) {
    const float2 corners[] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5),
        float2(-0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5),
    };
    float2 corner = corners[vertexID];
    DecalOut out;
    out.position = frame.viewProjection * decal.model * float4(corner, 0, 1);
    // The texture's top row lies along the square's top edge.
    out.uv = float2(corner.x + 0.5, 0.5 - corner.y);
    return out;
}

fragment float4 bookDecalFragment(
    DecalOut in [[stage_in]], constant Decal &decal [[buffer(3)]],
    texture2d<float> image [[texture(0)]]) {
    constexpr sampler trilinear(
        coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float4 color = image.sample(trilinear, in.uv);
    return float4(color.rgb * decal.tint.rgb, color.a) * decal.tint.a;
}
