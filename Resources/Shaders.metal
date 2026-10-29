#include <metal_stdlib>
using namespace metal;

// Design rules for OLED:
//  * Background is exactly 0,0,0 so those pixels are switched off.
//  * Thin lines and saturated colour instead of large bright fills, never pure white.
//  * Everything drifts (u.drift) and cycles colour (u.hue), so no pixel holds a static image.

struct Uniforms {
    float time, flow, bass, mid;
    float treble, level, beat, activity;
    float2 resolution;
    float2 drift;
    float hue, brightness, modeMix, pad0;
    int mode, mode2, theme, pad1;
};

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// ---------- helpers ----------

constant float TAU = 6.2831853;

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n * 17.0));
}

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

// Cosine palettes (iq). Each theme keeps colours saturated so the panel never goes white.
float3 palette(float t, int theme) {
    float3 a, b, c, d;
    switch (theme) {
        case 1: // ocean
            a = float3(0.05, 0.35, 0.55); b = float3(0.05, 0.30, 0.40); c = float3(1.0); d = float3(0.0, 0.10, 0.20); break;
        case 2: // ember
            a = float3(0.60, 0.25, 0.06); b = float3(0.40, 0.22, 0.06); c = float3(1.0); d = float3(0.0, 0.08, 0.15); break;
        case 3: // violet
            a = float3(0.45, 0.18, 0.62); b = float3(0.35, 0.18, 0.35); c = float3(1.0); d = float3(0.10, 0.0, 0.25); break;
        default: // spectrum
            a = float3(0.5); b = float3(0.5); c = float3(1.0); d = float3(0.0, 0.33, 0.67); break;
    }
    return a + b * cos(TAU * (c * t + d));
}

float spec(constant float* s, float x) {
    x = clamp(x, 0.0, 1.0) * 63.0;
    int i = int(x);
    int j = min(i + 1, 63);
    return mix(s[i], s[j], fract(x));
}

// ---------- 0: Halo — a spectrum ring with smoke inside and beat shockwaves ----------

float3 haloMode(float2 p, constant Uniforms& u, constant float* s) {
    float r = length(p);
    float a = atan2(p.y, p.x);
    float t = a / TAU + 0.5;
    // Mirror the spectrum around the ring so there is no seam; rotate it slowly.
    float m = abs(fract(t + u.flow * 0.01) * 2.0 - 1.0);
    float sv = spec(s, m) * u.activity;

    float breathe = 0.5 + 0.5 * sin(u.time * 0.5);
    float R = 0.25 + 0.025 * breathe * (1.0 - u.activity) + 0.035 * u.bass + sv * 0.13;
    float d = abs(r - R);
    float px = 1.0 / u.resolution.y;

    float core = smoothstep(px * 2.5, 0.0, d);
    float glow = 0.003 / (d + 0.003) * 0.25 + exp(-d * 35.0) * 0.18;
    float3 col = palette(m * 0.5 + u.hue + r * 0.4, u.theme) * (core * 0.9 + glow * (0.4 + 0.8 * u.level));

    // A comet of light orbiting the ring — the main motion in ambient mode.
    float hl = pow(0.5 + 0.5 * cos(a - u.time * 0.3), 12.0);
    col += palette(u.hue + 0.5, u.theme) * hl * exp(-d * 50.0) * 0.7;

    // Smoke inside the ring.
    float n = fbm(p * 3.0 + float2(u.flow * 0.07, -u.flow * 0.045));
    float inside = smoothstep(R, R * 0.15, r);
    col += palette(u.hue + n * 0.6, u.theme) * pow(n, 3.5) * inside * (0.15 + 0.7 * u.bass);

    // Spectrum flares outside the ring.
    float outside = smoothstep(R, R + 0.01, r) * exp(-(r - R) * 14.0);
    col += palette(m * 0.5 + u.hue, u.theme) * sv * sv * outside * 0.35;

    // Beat shockwave.
    float sr = R + (1.0 - u.beat) * 0.55;
    col += palette(u.hue + 0.25, u.theme) * exp(-abs(r - sr) * 90.0) * u.beat * u.beat * 0.5;
    return col;
}

// ---------- 1: Contours — thin stacked lines displaced by the spectrum ----------

float3 linesMode(float2 p, constant Uniforms& u, constant float* s) {
    float3 col = float3(0.0);
    const int N = 26;
    float px = 1.0 / u.resolution.y;
    float env = exp(-p.x * p.x * 5.0);
    float edgeFade = smoothstep(0.85, 0.55, abs(p.x));
    float sv = spec(s, clamp(sqrt(p.x * p.x + 0.002) * 1.15, 0.0, 1.0)) * u.activity;
    for (int i = 0; i < N; i++) {
        float fi = float(i) / float(N - 1);
        float y0 = mix(-0.3, 0.3, fi);
        float n = vnoise(float2(p.x * 3.5 + fi * 7.0, u.flow * 0.22 + fi * 3.0));
        float wave = 0.022 * (1.0 - u.activity) * sin(p.x * 6.0 + u.time * 0.35 + fi * 4.0);
        float disp = env * (n * 0.05 + sv * 0.16 * (0.55 + 0.45 * sin(fi * 11.0 + u.flow * 0.7)) + wave);
        float d = abs(p.y - y0 - disp);
        float line = smoothstep(px * 1.8, 0.0, d) * 0.9 + exp(-d * 350.0) * 0.25;
        float fade = 0.3 + 0.7 * (1.0 - abs(fi - 0.5) * 2.0);
        col += palette(u.hue + fi * 0.35 + p.x * 0.1, u.theme) * line * fade;
    }
    return col * edgeFade * (0.9 + 0.5 * u.level + 0.3 * u.beat);
}

// ---------- 2: Starfield — flying through stars, speed follows loudness ----------

float3 starsMode(float2 p, constant Uniforms& u, constant float* s) {
    // Only the stars are lit: no nebula or haze, the space between them stays pure black.
    float3 col = float3(0.0);
    const int L = 5;
    for (int i = 0; i < L; i++) {
        float fi = float(i);
        float depth = fract(u.flow * 0.08 + fi / float(L));
        float scale = mix(30.0, 3.0, depth);
        float fade = smoothstep(0.0, 0.35, depth) * smoothstep(1.0, 0.85, depth);
        float2 q = p * scale + fi * 31.7;
        float2 id = floor(q);
        float2 f = fract(q) - 0.5;
        float2 h = hash22(id);
        if (h.y < 0.45) continue;
        float2 off = (hash22(id + 7.3) - 0.5) * 0.6;
        float d = length(f - off);
        float band = spec(s, h.x) * u.activity;
        float size = mix(0.03, 0.07, h.x) * (1.0 + band * 0.8);
        // Glow ends well inside the cell so cells never show as faint squares.
        float glowR = min(size * 2.5, 0.18);
        float star = smoothstep(size, size * 0.15, d) + smoothstep(glowR, 0.0, d) * 0.15 * (0.4 + band);
        float twinkle = 0.65 + 0.35 * sin(u.time * (1.5 + h.y * 3.0) + h.x * 40.0);
        // Each star gets its own hue from the whole palette.
        float hue = hash21(id + fi * 13.1 + 3.7);
        col += palette(hue + u.hue, u.theme) * star * fade * twinkle * (0.9 + 0.9 * band + 0.4 * u.beat);
    }
    return col;
}

float3 render(int mode, float2 p, float2 uv, constant Uniforms& u, constant float* s) {
    switch (mode) {
        case 1: return linesMode(p, u, s);
        case 2: return starsMode(p, u, s);
        default: return haloMode(p, u, s);
    }
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant Uniforms& u [[buffer(0)]],
                      constant float* s [[buffer(1)]]) {
    float2 frag = float2(in.pos.x, u.resolution.y - in.pos.y);
    float2 uv = frag / u.resolution;
    float2 p = (frag - 0.5 * u.resolution) / u.resolution.y - u.drift;

    float3 col = render(u.mode, p, uv, u, s);
    if (u.modeMix > 0.0) {
        col = mix(col, render(u.mode2, p, uv, u, s), u.modeMix);
    }

    col *= u.brightness;
    col = 1.0 - exp(-col * 1.3);            // soft tone-map: highlights roll off, never clip to white
    col = max(col - 0.008, 0.0) / 0.992;    // crush the near-black haze to true black so OLED pixels stay off
    return float4(col, 1.0);
}
