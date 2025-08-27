#include <metal_stdlib>
#include "OperationShaderTypes.h"
using namespace metal;

struct SkinUniforms {
    float smoothMix;

    float skinHueCenter; // radians [0, 2π)
    float skinHueWidth;  // radians (half-width)
    float skinSatMin;
    float skinSatMax;
    float skinYMin;
    float skinYMax;

    float feather;       // 0..1 extra softness
};

inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1e-10;
    float h = abs(q.z + (q.w - q.y) / (6.0 * d + e)); // [0,1)
    float s = d / (q.x + e);
    float v = q.x;
    return float3(h * 6.28318530718, s, v); // H in radians
}

inline float luma709(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

fragment half4 skinOnlyBlendFragment(TwoInputVertexIO inFrag             [[stage_in]],
                                     texture2d<half> originalTex         [[texture(0)]],
                                     texture2d<half> blurredTex          [[texture(1)]],
                                     constant SkinUniforms& U            [[buffer(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = inFrag.textureCoordinate;

    half4 o = originalTex.sample(s, uv);
    half4 b = blurredTex.sample(s, uv);

    float3 rgb = float3(o.rgb);
    float y    = luma709(rgb);
    float3 hsv = rgb2hsv(rgb);
    float  h   = hsv.x; // radians
    float  sat = hsv.y;

    // Hue ring distance
    float dh = abs(h - U.skinHueCenter);
    dh = min(dh, 6.28318530718 - dh);

    // Gates with soft edges (smoothstep)
    float hueGate = smoothstep(U.skinHueWidth, max(0.0, U.skinHueWidth - 0.15), dh); // narrower center → stronger
    float satGate = smoothstep(U.skinSatMin, U.skinSatMin + 0.08, sat)
                  * smoothstep(U.skinSatMax + 0.08, U.skinSatMax, sat);
    float yGate   = smoothstep(U.skinYMin, U.skinYMin + 0.05, y)
                  * smoothstep(U.skinYMax + 0.05, U.skinYMax, y);

    // Combined mask
    float m = clamp(hueGate * satGate * yGate, 0.0, 1.0);

    // Extra feathering: expand then contract a bit (softer edges)
    float f = clamp(U.feather, 0.0, 1.0);
    m = smoothstep(0.0, 1.0, mix(m, m*m, f)); // small bias toward softer transition

    // Blend blurred over original only on mask
    float k = clamp(U.smoothMix, 0.0, 1.0) * m;
    float3 outRGB = mix(float3(o.rgb), float3(b.rgb), k);

    return half4(half3(outRGB), o.a);
}
