#include <metal_stdlib>
using namespace metal;

// GPU intensity graph: a bright line over black with a downward fade fill,
// computed per-pixel so the CPU only hands over the sample array each frame.
// `samples` are 0…1 (oldest→newest); SwiftUI passes the pointer + `count`.
// `bounds.zw` is the view size in points. Matches the old Canvas look: white
// line ~1.1pt, fill fading white(.9)→gray(.28 @0.18h)→clear(@0.5h) by abs-y.
[[stitchable]] half4 intensityGraph(float2 pos, half4 color,
                                    float4 bounds,
                                    device const float *samples, int count) {
    float w = bounds.z, h = bounds.w;
    if (count < 2 || w <= 0.0 || h <= 0.0) return half4(0.0, 0.0, 0.0, 1.0);

    // Linear-interpolate the sample under this column.
    float fx = clamp(pos.x / w, 0.0, 1.0) * float(count - 1);
    int i0 = int(floor(fx));
    int i1 = min(i0 + 1, count - 1);
    float v = mix(samples[i0], samples[i1], fx - float(i0));
    float lineY = (1.0 - v) * h;            // top = 0

    half3 rgb = half3(0.0);                  // black

    // Downward fade fill beneath the line (gradient keyed to absolute y).
    if (pos.y >= lineY) {
        float t = pos.y / h;
        half a; half3 fill;
        if (t < 0.18) { a = mix(half(0.9), half(0.28), half(t / 0.18)); fill = half3(1.0); }
        else if (t < 0.5) { a = mix(half(0.28), half(0.0), half((t - 0.18) / 0.32)); fill = half3(0.5); }
        else { a = half(0.0); fill = half3(0.5); }
        rgb = mix(rgb, fill, a);
    }

    // The bright line itself, soft-edged at ~1.1pt.
    half lineA = half(smoothstep(1.6, 0.4, abs(pos.y - lineY))) * half(0.92);
    rgb = mix(rgb, half3(1.0), lineA);

    return half4(rgb, 1.0);
}
