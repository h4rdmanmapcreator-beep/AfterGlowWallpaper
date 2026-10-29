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
    float hue, brightness, modeMix, kick;
    int mode, mode2, theme, flags;   // flags bit 0: black hole orbiting stars
    float4 rippleAge, rippleAmp;     // last four bass hits: seconds since, strength
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

float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v / 0.875;
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

float3 rgb(uint h) {
    return float3(float((h >> 16) & 255u), float((h >> 8) & 255u), float(h & 255u)) / 255.0;
}

// Smooth looping gradient through four colours.
float3 stops4(float t, float3 c0, float3 c1, float3 c2, float3 c3) {
    t = fract(t) * 4.0;
    int i = int(t);
    float f = smoothstep(0.0, 1.0, fract(t));
    float3 a = i == 0 ? c0 : (i == 1 ? c1 : (i == 2 ? c2 : c3));
    float3 b = i == 0 ? c1 : (i == 1 ? c2 : (i == 2 ? c3 : c0));
    return mix(a, b, f);
}

// Theme ids match `Theme` raw values in Settings.swift. Colours stay saturated so the panel never goes white.
float3 palette(float t, int theme) {
    switch (theme) {
        case 1: return stops4(t, rgb(0x0a2a6b), rgb(0x0f6fb0), rgb(0x18c0d0), rgb(0x0a3a8a)); // ocean
        case 2: return stops4(t, rgb(0xff3b0a), rgb(0xff8a1e), rgb(0xc21d3a), rgb(0xff5a14)); // ember
        case 3: return stops4(t, rgb(0x6b1fd1), rgb(0xb03cff), rgb(0x3a1aa8), rgb(0xe05cff)); // violet
        case 4: return stops4(t, rgb(0xff5a1f), rgb(0xe8202a), rgb(0x5a1fb5), rgb(0xff8a2a)); // sunset
        case 5: return stops4(t, rgb(0xff2bd6), rgb(0x7a2bff), rgb(0x00e5ff), rgb(0xf8f000)); // cyberpunk
        case 7: return stops4(t, rgb(0x1f8a3a), rgb(0x7cd13a), rgb(0x0f5c4a), rgb(0xc8e04a)); // nature
        case 9: return stops4(t, rgb(0x3fa9ff), rgb(0x8fd8ff), rgb(0x2a5cff), rgb(0x6ef0ff)); // ice
        default: return 0.5 + 0.5 * cos(TAU * (t + float3(0.0, 0.33, 0.67)));                // spectrum
    }
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
    if (edgeFade <= 0.0) return col;
    float sv = spec(s, clamp(sqrt(p.x * p.x + 0.002) * 1.15, 0.0, 1.0)) * u.activity;
    // Farthest any line can be pushed at this x; lines that can't reach this pixel are skipped.
    float reach = env * (0.05 + sv * 0.16 + 0.022 * (1.0 - u.activity)) + 0.02;
    for (int i = 0; i < N; i++) {
        float fi = float(i) / float(N - 1);
        float y0 = mix(-0.3, 0.3, fi);
        if (abs(p.y - y0) > reach) continue;
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

// Buffer 1 layout: [0, 64) bands, [64, 128) peak caps, [128, 384) waveform,
// then 28 orbiting stars as (x, y, ±size, hue): position in event-horizon radii, size < 0 when in front of the hole.
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

// ---------- 5: Black Hole — lensed accretion disk, jets, orbiting stars, spacetime ripples ----------

// Gas texture in the disk plane. Inner gas orbits faster (Kepler), which winds the noise into
// streaks; two phases cross-fade so the winding never grows into aliasing over long runs.
float diskTexture(float D, float phi, constant Uniforms& u) {
    float tau = u.flow * 0.08;
    float tA = fract(tau), tB = fract(tau + 0.5);
    float wA = 1.0 - abs(2.0 * tA - 1.0);
    float shear = 1.0 / pow(D, 1.5);
    float rigid = phi - u.flow * 0.12;
    float aA = rigid - shear * tA * 7.0;
    float aB = rigid - shear * tB * 7.0;
    float nA = fbm3(D * float2(cos(aA), sin(aA)) * 1.4 + floor(tau) * 7.31);
    float nB = fbm3(D * float2(cos(aB), sin(aB)) * 1.4 + floor(tau + 0.5) * 7.31 + 3.1);
    return mix(nB, nA, wA);
}

// Light from the disk at radius D (in event-horizon radii) and azimuth phi (pi/2 = far side).
float3 diskEmission(float D, float phi, float rin, float rout, constant Uniforms& u, constant float* s) {
    float band = smoothstep(rin, rin * 1.12, D) * (1.0 - smoothstep(rout * 0.6, rout * 1.15, D));
    if (band <= 0.0) return float3(0.0);
    float turb = diskTexture(D, phi, u);
    float rings = 0.5 + 0.5 * sin(D * 9.0 + turb * 6.0);
    float tex = mix(turb, rings, 0.45);
    float heat = 1.0 - smoothstep(rin, rout, D);
    float doppler = 0.35 + 0.65 * (0.5 - 0.5 * cos(phi));   // the side spinning towards us is brighter
    float sv = spec(s, clamp((D - rin) / (rout - rin), 0.0, 1.0)) * u.activity;
    float energy = 0.8 + 0.8 * u.level + 0.7 * sv + 0.9 * u.kick;
    return palette(u.hue + heat * 0.35 + 0.1 * tex, u.theme)
         * band * (0.25 + 1.1 * heat * heat) * (0.35 + 0.9 * tex) * doppler * energy;
}

float3 blackHoleMode(float2 p0, constant Uniforms& u, constant float* s) {
    float px = 1.0 / u.resolution.y;
    float rs = 0.13 + 0.012 * u.bass + 0.008 * u.kick;

    // Each hard bass hit sends a gravitational wave outwards that warps everything it passes.
    float r0 = length(p0);
    float disp = 0.0, crest = 0.0;
    for (int k = 0; k < 4; k++) {
        float age = u.rippleAge[k];
        float amp = u.rippleAmp[k];
        if (age > 4.0 || amp <= 0.0) continue;
        float x = r0 - (rs * 1.3 + age * 0.45);
        float env = amp * exp(-age * 0.9) * exp(-x * x * 90.0);
        disp += env * 0.022 * sin(x * 70.0);
        crest += amp * exp(-age * 1.2) * exp(-x * x * 6000.0);
    }
    float2 p = p0 - p0 / max(r0, 1e-4) * disp;
    float r = length(p);
    float rn = r / rs;

    // Frame aligned with the disk; the disk is seen from slightly above.
    float rot = -0.18 + 0.08 * sin(u.time * 0.05);
    float cr = cos(rot), sr = sin(rot);
    float2 pr = float2(cr * p.x + sr * p.y, -sr * p.x + cr * p.y);
    float th = atan2(pr.y, pr.x);
    float rin = 1.6, rout = 3.6 + 0.8 * u.level;
    float hole = smoothstep(rs, rs - px * 1.5, r);

    float3 bg = float3(0.0);   // things behind the hole (hidden inside the horizon)
    float3 fg = float3(0.0);   // things in front of it

    // Background stars, bent around the hole like a gravitational lens.
    float E = rs * 1.9;
    float2 src = p * (1.0 - E * E / max(r * r, 1e-5));
    float2 sq = src * 30.0;
    float2 sid = floor(sq);
    float2 sh = hash22(sid);
    float sd = length(fract(sq) - 0.5 - (hash22(sid + 4.1) - 0.5) * 0.6);
    float star = smoothstep(0.07, 0.0, sd) * step(0.8, sh.x) * smoothstep(rs * 1.05, rs * 1.5, r);
    bg += palette(sh.y + u.hue, u.theme) * star * (0.35 + 0.4 * u.treble) * (0.6 + 0.4 * sin(u.time * 2.0 + sh.y * 30.0));

    // Far side of the disk, bent up over the top of the hole and (thinner) under it.
    if (rn > 1.0) {
        float up = smoothstep(-0.35, 0.35, sin(th));   // blend smoothly from the lower to the upper image
        float D = rin + (rn - 1.08) / mix(0.55, 1.35, up) * (rout - rin);
        bg += diskEmission(D, abs(th), rin, rout, u, s) * smoothstep(1.02, 1.12, rn) * mix(0.45, 0.95, up);
    }

    // The disk itself, nearly edge-on. Its near half crosses in front of the hole.
    float2 dq = float2(pr.x, pr.y / 0.2) / rs;
    float3 disk = diskEmission(length(dq), atan2(dq.y, dq.x), rin, rout, u, s);
    if (dq.y < 0.0) fg += disk; else bg += disk;

    // Photon ring: thin, shimmering, flaring on kicks.
    float shimmer = 0.7 + 0.3 * sin(th * 6.0 + u.flow * 1.5);
    bg += palette(u.hue + 0.45, u.theme) * exp(-abs(r - rs * 1.04) * 380.0) * shimmer * (0.6 + 0.6 * u.level + 0.8 * u.kick);

    // Relativistic jets along the disk axis, pumped by the bass.
    float jy = abs(pr.y);
    float jw = 0.007 + jy * 0.035;
    float jet = exp(-pr.x * pr.x / (jw * jw)) * smoothstep(rs * 0.9, rs * 1.6, jy) * exp(-jy * 2.2);
    if (jet > 0.002) {
        float jflow = 0.55 + 0.45 * vnoise(float2(pr.x * 40.0, jy * 18.0 - u.flow * 2.0));
        bg += palette(u.hue + 0.6, u.theme) * jet * jflow * (0.08 + 0.25 * u.bass + 0.5 * u.kick);
    }

    // Stars orbiting the hole. Behind it they are seen through the lens and smear into arcs.
    // Their orbits are worked out once per frame on the CPU (Engine.orbitStars). Stars rarely overlap,
    // so only the nearest one in front of and behind the hole is shaded.
    if ((u.flags & 1) != 0) {
        constant float4* stars = (constant float4*)(s + 384);
        float4 nearFar = float4(1.0, 0.0, 0.0, 0.0);    // (distance, size, hue, -)
        float4 nearFront = float4(1.0, 0.0, 0.0, 0.0);
        for (int i = 0; i < 28; i++) {
            float4 st = stars[i];
            float2 o = st.xy * rs;
            o = float2(cr * o.x - sr * o.y, sr * o.x + cr * o.y);
            if (st.z > 0.0) {
                float d = length(src - o);
                if (d < nearFar.x) nearFar = float4(d, st.z, st.w, 0.0);
            } else {
                float d = length(p - o);
                if (d < nearFront.x) nearFront = float4(d, -st.z, st.w, 0.0);
            }
        }
        float shine = 0.7 + 0.6 * u.treble;
        if (nearFar.x < 0.03)
            bg += palette(u.hue + nearFar.z, u.theme) * shine
                * (smoothstep(nearFar.y, nearFar.y * 0.2, nearFar.x) + exp(-nearFar.x * 260.0) * 0.25);
        if (nearFront.x < 0.03)
            fg += palette(u.hue + nearFront.z, u.theme) * shine
                * (smoothstep(nearFront.y, nearFront.y * 0.2, nearFront.x) + exp(-nearFront.x * 260.0) * 0.25);
    }

    bg += palette(u.hue + 0.2, u.theme) * crest * 0.3;
    return bg * (1.0 - hole) + fg;
}

// ---------- 6: Gradients — soft colour fields drifting and breathing with the music ----------

float3 gradientsMode(float2 p, constant Uniforms& u, constant float* s) {
    float t = u.flow * 0.05 + u.time * 0.008;
    // Only very low frequencies are used anywhere, so every transition stays soft.
    float2 w = p + (0.1 + 0.08 * u.mid) * float2(sin(p.y * 1.6 + t * 1.3), sin(p.x * 1.3 - t * 1.1));
    float3 acc = float3(0.0);
    float total = 0.0;
    // Five colour fields, one per frequency range: each swells and brightens with its part of the music.
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 c = float2(0.6 * sin(t * (0.7 + fi * 0.13) + fi * 1.9), 0.34 * cos(t * (0.55 + fi * 0.17) + fi * 2.7));
        float band = spec(s, (fi + 0.5) / 5.0) * u.activity;
        float rad = 0.19 + 0.04 * sin(u.time * 0.21 + fi * 1.3) + 0.07 * band + 0.04 * u.kick;
        // Stretched, slowly turning fields read as sweeps of colour rather than round blobs.
        float ang = t * 0.3 + fi * 1.1;
        float2 d = w - c;
        d = float2(cos(ang) * d.x + sin(ang) * d.y, -sin(ang) * d.x + cos(ang) * d.y) * float2(0.55, 1.0);
        float g = exp(-dot(d, d) / (rad * rad)) * (0.6 + 0.8 * band);
        acc += palette(u.hue + fi * 0.21 + t * 0.1, u.theme) * g;
        total += g;
    }
    float3 colour = acc / max(total, 1e-4);   // blended like a mesh gradient, never summed towards white
    float lum = 1.0 - exp(-total * 1.6);
    return colour * lum * (0.75 + 0.45 * u.level + 0.2 * u.kick) * exp(-dot(p, p) * 0.5);
}

// ---------- 7: Neon Grid — retro-futuristic floor, sun and a spectrum skyline ----------

float3 gridMode(float2 p, constant Uniforms& u, constant float* s) {
    float3 col = float3(0.0);
    float px = 1.0 / u.resolution.y;
    float y = p.y + 0.02;   // height above the horizon

    // Derivatives are taken for every pixel so they stay valid across the horizon.
    float z = 0.22 / max(-y, 1e-3);
    float2 g = float2(p.x * z, z + u.flow * 0.9) * 2.0;
    float2 fw = fwidth(g);

    if (y < 0.0) {
        float2 gd = abs(fract(g - 0.5) - 0.5) / max(fw, 1e-4);
        float line = 1.0 - min(min(gd.x, gd.y) / 1.2, 1.0);
        line *= 1.0 - smoothstep(0.15, 0.5, max(fw.x, fw.y));   // drop lines thinner than a pixel near the horizon
        float fade = exp(-z * 0.25) * smoothstep(0.0, 0.04, -y);
        col += palette(u.hue + z * 0.04, u.theme) * line * fade * (0.9 + 0.5 * u.bass + 0.4 * u.beat);
    } else {
        // Skyline: low hills in the middle, spectrum-driven peaks towards the sides.
        float hills = (0.03 + 0.05 * fbm(float2(p.x * 4.0 + u.flow * 0.02, 1.0))) * smoothstep(0.1, 0.6, abs(p.x));
        float hgt = 0.01 + hills + spec(s, abs(p.x) * 1.1) * 0.12 * u.activity;
        if (y < hgt) {
            col += palette(u.hue + 0.6, u.theme) * smoothstep(px * 2.0, 0.0, hgt - y) * 0.8;
        } else {
            col += palette(u.hue + 0.6, u.theme) * smoothstep(px * 2.0, 0.0, y - hgt) * 0.8;
            // Sun with scrolling slits, widening towards the bottom.
            float2 sp = float2(p.x, y - 0.17);
            float srad = 0.15 + 0.02 * u.bass;
            float sdist = length(sp);
            float disc = smoothstep(srad, srad - px * 2.0, sdist);
            float gap = clamp(-sp.y * 3.0, 0.0, 0.75);
            float slits = step(gap, fract(sp.y * 18.0 - u.flow * 0.08));
            float3 sun = palette(u.hue + 0.3 * (sp.y / srad * 0.5 + 0.5), u.theme);
            col += sun * disc * slits * (0.45 + 0.3 * u.level + 0.2 * u.beat);
            col += sun * exp(-max(sdist - srad, 0.0) * 14.0) * (1.0 - disc) * 0.12;
            // A few stars.
            float2 q = p * 45.0;
            float2 h = hash22(floor(q));
            float st = smoothstep(0.07, 0.0, length(fract(q) - 0.5 - (h - 0.5) * 0.6)) * step(0.88, h.x);
            col += palette(h.y + u.hue, u.theme) * st * smoothstep(0.05, 0.25, y) * (0.3 + 0.5 * u.treble);
        }
    }
    col += palette(u.hue + 0.1, u.theme) * exp(-abs(y) * 140.0) * (0.5 + 0.6 * u.level);
    return col;
}

float3 render(int mode, float2 p, float2 uv, constant Uniforms& u, constant float* s) {
    switch (mode) {
        case 1: return linesMode(p, u, s);
        case 2: return starsMode(p, u, s);
        case 3: return barsMode(p, u, s);
        case 4: return scopeMode(p, u, s);
        case 5: return blackHoleMode(p, u, s);
        case 6: return gradientsMode(p, u, s);
        case 7: return gridMode(p, u, s);
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
