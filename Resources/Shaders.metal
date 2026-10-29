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

// Buffer 1 layout: [0, 64) bands, [64, 128) peak caps, [128, 384) waveform.
float peakAt(constant float* s, float x) { return spec(s + 64, x); }

float waveAt(constant float* s, float x) {
    x = clamp(x, 0.0, 1.0) * 255.0;
    int i = int(x);
    int j = min(i + 1, 255);
    return mix(s[128 + i], s[128 + j], fract(x));
}

// ---------- 3: Equalizer — mirrored bars with falling peak caps ----------

float3 barsMode(float2 p, constant Uniforms& u, constant float* s) {
    const float N = 32.0;   // bars on each side of the centre
    const float W = 0.78;   // half-width of the whole equalizer
    float ax = abs(p.x);
    if (ax > W) return float3(0.0);
    float slot = W / N;
    float idx = floor(ax / slot);
    float cx = (idx + 0.5) * slot;
    float x01 = (idx + 0.5) / N;    // 0 at the centre (bass), 1 at the edges (treble)
    float px = 1.0 / u.resolution.y;

    float v = spec(s, x01) * u.activity;
    float idle = 0.012 + 0.03 * (0.5 + 0.5 * sin(u.time * 0.7 - x01 * 9.0 + 2.0 * sin(u.time * 0.23)));
    float hgt = mix(idle, 0.015 + v * 0.36, u.activity);
    float halfW = slot * 0.3;

    float ay = abs(p.y);
    float2 q = float2(abs(ax - cx) - halfW, ay - hgt);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float fill = smoothstep(px, -px, d);
    float glow = exp(-max(d, 0.0) * 400.0) * 0.3;
    float tip = smoothstep(hgt * 0.4, hgt, ay);   // dim bodies, bright tips: less lit area on OLED
    float3 c = palette(u.hue + x01 * 0.6 + ay * 0.8, u.theme);
    float3 col = c * (fill * (0.2 + 0.8 * tip) + glow);

    float capY = max(peakAt(s, x01) * 0.36 + 0.015, hgt) + 0.012;
    float cap = smoothstep(px * 1.5, 0.0, abs(ay - capY) - 0.002) * step(abs(ax - cx), halfW) * u.activity;
    col += palette(u.hue + x01 * 0.6 + 0.3, u.theme) * cap * 0.8;
    return col * (0.85 + 0.4 * u.beat);
}

// ---------- 4: Oscilloscope — the actual waveform as a thin glowing trace ----------

float scopeY(float x01, float k, float px, constant Uniforms& u, constant float* s) {
    float env = smoothstep(0.0, 0.12, x01) * smoothstep(1.0, 0.88, x01);   // taper the ends to the centre line
    float amp = (0.2 + 0.1 * u.bass) * (1.0 - k * 0.25);
    float w = waveAt(s, x01 + k * 0.012) * u.activity;
    float idle = 0.03 * sin(px * (5.0 + k * 2.0) + u.time * (0.6 + k * 0.25)) * sin(px * 1.3 - u.time * 0.21 + k);
    return (w * amp + idle * (1.0 - u.activity)) * env;
}

float3 scopeMode(float2 p, constant Uniforms& u, constant float* s) {
    const float W = 0.8;
    float x01 = p.x / (2.0 * W) + 0.5;
    if (x01 < 0.0 || x01 > 1.0) return float3(0.0);
    float pxl = 1.0 / u.resolution.y;
    float e = 0.002;
    float3 col = float3(0.0);
    // Main trace plus two offset echoes in neighbouring colours.
    for (int i = 0; i < 3; i++) {
        float k = float(i);
        float y = scopeY(x01, k, p.x, u, s);
        float y2 = scopeY(x01 + e, k, p.x + e * 2.0 * W, u, s);
        float slope = (y2 - y) / (e * 2.0 * W);
        float d = abs(p.y - y) / sqrt(1.0 + slope * slope);
        float line = smoothstep(pxl * (2.2 - k * 0.6), 0.0, d) + exp(-d * 90.0) * 0.15;
        col += palette(u.hue + k * 0.18 + x01 * 0.3, u.theme) * line * (1.0 - k * 0.35);
    }
    return col * (0.8 + 0.5 * u.level);
}

// ---------- 5: Ripples — raindrops on black water, faster and wider with the music ----------

float3 ripplesMode(float2 p, constant Uniforms& u, constant float* s) {
    float3 col = float3(0.0);
    float px = 1.0 / u.resolution.y;
    float aspect = u.resolution.x / u.resolution.y;
    float tb = u.flow * 0.9;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float period = 3.0 + hash21(float2(fi, 1.7)) * 3.0;
        float tt = tb / period + hash21(float2(fi, 9.1));
        float lt = fract(tt);
        float2 h = hash22(float2(fi * 7.3, floor(tt)));
        float2 c = (h - 0.5) * float2(aspect * 0.85, 0.8);
        float r = length(p - c);
        float band = spec(s, hash21(float2(fi, 3.3))) * u.activity;
        float R = lt * (0.25 + 0.25 * h.x + band * 0.15);
        float fade = (1.0 - lt) * (1.0 - lt) * smoothstep(0.0, 0.05, lt);
        float3 cc = palette(u.hue + h.y * 0.8, u.theme);
        for (int k = 0; k < 2; k++) {
            float rk = R - float(k) * 0.035 * (1.0 + band);
            if (rk <= 0.0) continue;
            float d = abs(r - rk);
            float ring = smoothstep(px * 2.0, 0.0, d) + exp(-d * 120.0) * 0.2;
            col += cc * ring * fade * (k == 0 ? 1.0 : 0.5) * (0.6 + band);
        }
    }
    // Each beat drops a wide ring from the centre.
    float d0 = abs(length(p) - (1.0 - u.beat) * 0.9);
    col += palette(u.hue + 0.5, u.theme) * (smoothstep(px * 2.5, 0.0, d0) + exp(-d0 * 60.0) * 0.3) * u.beat * u.beat;
    return col;
}

// ---------- 6: Orbits — bodies on tilted orbits, one per frequency range ----------

float3 orbitsMode(float2 p, constant Uniforms& u, constant float* s) {
    float3 col = float3(0.0);
    float px = 1.0 / u.resolution.y;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float band = spec(s, (fi + 0.5) / 6.0) * u.activity;
        float R = 0.12 + fi * 0.072 + band * 0.025;
        float tilt = 0.35 + 0.25 * sin(fi * 1.7);
        // Orbits precess slowly so their lines never sit on the same pixels.
        float prec = u.time * 0.01 * (fi + 1.0) * dir + fi * 0.9;
        float cs = cos(prec), sn = sin(prec);
        float2 q = float2(cs * p.x + sn * p.y, -sn * p.x + cs * p.y);
        q.y /= tilt;
        float rq = max(length(q), 1e-4);
        float g = length(float2(q.x, q.y / tilt)) / rq;
        float de = abs(rq - R) / g;   // distance to the ellipse in screen space

        float b = u.flow * (0.9 / (1.0 + fi * 0.45)) * dir + fi * 2.1;
        float behind = fract((b - atan2(q.y, q.x)) * dir / TAU);
        float onOrbit = smoothstep(px * 2.5, 0.0, de);
        float trail = exp(-behind * 6.0) * onOrbit;
        float orbitLine = smoothstep(px * 1.5, 0.0, de) * 0.14;

        float2 bp = float2(R * cos(b), R * sin(b) * tilt);
        bp = float2(cs * bp.x - sn * bp.y, sn * bp.x + cs * bp.y);
        float db = length(p - bp);
        float size = 0.009 + band * 0.014;
        float body = smoothstep(size, size * 0.3, db) + exp(-db * 70.0) * 0.25 * (0.4 + band);

        col += palette(u.hue + fi * 0.16, u.theme) * (orbitLine + trail * (0.5 + band) + body * (0.8 + band));
    }
    float r = length(p);
    col += palette(u.hue + 0.5, u.theme) * exp(-r * 60.0) * (0.25 + 0.6 * u.bass);
    return col;
}

float3 render(int mode, float2 p, float2 uv, constant Uniforms& u, constant float* s) {
    switch (mode) {
        case 1: return linesMode(p, u, s);
        case 2: return starsMode(p, u, s);
        case 3: return barsMode(p, u, s);
        case 4: return scopeMode(p, u, s);
        case 5: return ripplesMode(p, u, s);
        case 6: return orbitsMode(p, u, s);
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
