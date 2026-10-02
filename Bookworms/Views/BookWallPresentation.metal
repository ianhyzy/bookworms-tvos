#include <metal_stdlib>
using namespace metal;

// Draws a Book Wall frame slot into the layer's drawable with one full-screen triangle.
// Sampling and attachment conversion preserve sRGB on both sides of the pass, and linear
// filtering also scales smaller internal textures.

struct WallPresentationVertex {
    float4 position [[position]];
    float2 uv;
};

vertex WallPresentationVertex wallPresentationVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    const float2 coordinates[] = { float2(0, 1), float2(2, 1), float2(0, -1) };
    WallPresentationVertex result;
    result.position = float4(positions[vertexID], 0, 1);
    result.uv = coordinates[vertexID];
    return result;
}

fragment float4 wallPresentationFragment(
    WallPresentationVertex input [[stage_in]], texture2d<float> color [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(color.sample(linearSampler, input.uv).rgb, 1);
}
