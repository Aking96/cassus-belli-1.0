// src/background.glsl
// Procedural animated hexa-chevron / interlocking-cube diamond lattice
// background (Cassus Belli Background Spec). Straight, static tessellation
// -- all motion comes from each diamond's own brightness/scale/shimmer
// easing over time, never from warping the grid itself. Warm on the
// player's side (bottom), cool on the enemy's (top), converging to a calm,
// subdued band right around the battlefield (the screen's vertical middle)
// so the pattern never competes with the cards there. Reacts to the mouse
// with a bright additive light at the cursor plus a subtle color shift,
// both falling off with distance, stronger near the battlefield.
// Reads no game state directly -- see src/background.lua for the uniforms.

extern number time;
extern vec2 resolution;
extern vec3 enemyColor;        // top territory color, randomized per battle
extern vec3 playerColor;       // bottom territory color, randomized per battle
extern vec2 mouse;             // screen-space cursor position
extern number battleIntensity; // 0 = normal, 1 = battle, 2 = War

const vec3 BASE_COLOR = vec3(0.02, 0.03, 0.05);

float hash21(vec2 p)
{
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = screen_coords / resolution;

    // Faster, brighter, more reactive the tenser the current moment is.
    float speedMul = 1.0 + battleIntensity * 0.35;
    float t = time * speedMul;

    // 0 right at the battlefield's vertical band (screen middle), easing to
    // 1 by a bit over a third of the way toward either hand -- multiplies
    // into the lattice's presence below so it stays calm and legible over
    // the battlefield instead of competing with the cards there.
    float centerDist = abs(uv.y - 0.5);
    float centerPresence = smoothstep(0.03, 0.4, centerDist);

    // Vertical territory tint: enemy (top) to player (bottom) -- a plain
    // mix already passes through a rich blended midpoint on its own.
    vec3 territory = mix(enemyColor, playerColor, smoothstep(0.0, 1.0, uv.y));

    // Interlocking diamond lattice: a 45-degree-rotated grid tessellates
    // perfectly (no gaps, no overlap checks needed), reading as the
    // hexa-chevron/cube pattern from the reference image.
    float cell = resolution.x / 22.0;
    vec2 grid = vec2((screen_coords.x + screen_coords.y) / cell,
                      (screen_coords.y - screen_coords.x) / cell);
    vec2 cellId = floor(grid);
    vec2 localUv = fract(grid);

    float phase = hash21(cellId + 31.0) * 6.28318;
    float speed = mix(0.15, 0.35, hash21(cellId + 53.0)) * speedMul;
    float glow = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * speed + phase));

    // A gentle shimmer of each diamond's internal pattern -- "shift" without
    // ever moving a cell's identity/boundaries, so there's nothing to
    // teleport or blend across cell edges.
    vec2 shimmer = vec2(sin(t * 0.25 + phase), cos(t * 0.2 + phase)) * 0.05;
    vec2 facetUv = localUv + shimmer;

    // Two-tone "cube" shading: splitting the cell diagonally into a
    // lighter and darker facet reads as a subtle bevel, echoing the
    // interlocking-cube look of the reference pattern.
    float facet = (facetUv.x + facetUv.y < 1.0) ? 1.0 : 0.72;

    // Thin border near each diamond's edge, so individual cells stay
    // readable as a lattice rather than a blurred wash.
    float edgeDist = min(min(localUv.x, 1.0 - localUv.x), min(localUv.y, 1.0 - localUv.y));
    float edgeLine = smoothstep(0.0, 0.05, edgeDist);

    // Subdued toward the battlefield: smaller/lower-contrast/darker/
    // tighter, per the spec, rather than the flashier treatment further
    // out toward the hands.
    float presenceScale = mix(0.35, 1.0, centerPresence);
    float cellStrength = glow * facet * edgeLine * presenceScale;
    cellStrength *= (1.0 + battleIntensity * 0.25);

    vec3 col = BASE_COLOR + territory * cellStrength * 0.55;

    // Mouse hover: no light, no wash -- just the background subtly going
    // negative in a radius around the cursor, falling off with distance.
    // Reacts a bit more strongly the closer the cursor sits to the
    // battlefield.
    float mouseDist = length(screen_coords - mouse) / resolution.x;
    float proximityBoost = 1.0 + (1.0 - centerPresence) * 0.7;
    float intensityBoost = 1.0 + battleIntensity * 0.2;

    float shiftRadius = 0.12 + (1.0 - centerPresence) * 0.08;
    float shiftFalloff = 1.0 - smoothstep(0.0, shiftRadius, mouseDist);
    float shiftStrength = clamp(shiftFalloff * 0.3 * proximityBoost * intensityBoost, 0.0, 0.4);

    // Inverting a near-black color naturally produces near-white, which
    // reads as a bright glow no matter how low shiftStrength is -- rescale
    // the negative's brightness back down to match the original so only
    // the HUE shifts (a true "gone negative" color swap), not the
    // brightness.
    vec3 negative = vec3(1.0) - col;
    float originalLum = dot(col, vec3(0.299, 0.587, 0.114));
    float negativeLum = max(dot(negative, vec3(0.299, 0.587, 0.114)), 0.001);
    negative *= (originalLum + 0.04) / negativeLum;

    col = mix(col, negative, shiftStrength);

    // Very subtle vignette -- corners a touch darker than center.
    float vignette = smoothstep(0.95, 0.35, length((uv - 0.5) * vec2(1.0, resolution.y / resolution.x)));
    col *= mix(0.85, 1.0, vignette);

    return vec4(col, 1.0);
}
