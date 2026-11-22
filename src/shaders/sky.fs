// Background starfield (main.zig: drawSky): a sky sphere of hashed stars that
// turns with the camera. main.zig prepends a header per GLSL version
// (#version, precision, FRAG; SKY_OFF where WebGL lacks highp, which the hash
// needs) and draws it additively over the background.
// A pixel's view ray is `fwd` + x·`right` + y·`up`, x and y in -1..1 across
// the screen (main.zig scales right and up by the field of view).
uniform vec2 resolution;
uniform vec3 fwd;
uniform vec3 right;
uniform vec3 up;
uniform float time;

const vec3 tint = vec3(0.78, 0.84, 0.95); // cool white
// Two layers: many faint small stars, fewer brighter ones. Cells: cubes per
// unit of the sphere's radius; share: of the cells hold a star; size: its
// radius in cube widths.
const float fine_cells = 90.0, fine_share = 0.05, fine_size = 0.22, fine_gain = 0.55;
const float big_cells = 35.0, big_share = 0.03, big_size = 0.12, big_gain = 1.0;
const float dimmest = 0.35; // star brightness ranges dimmest..1
const float twinkle_share = 0.3; // of the stars twinkle
const float twinkle_depth = 0.45; // dimmest twinkle, as a fraction off
const float twinkle_phases = 40.0; // spreads the twinklers' phases

// Pseudo-random 0..1 per integer cell (needs highp: cells reach ~100).
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1) * 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// One layer's brightness along `dir`. A star counts only if its whole disc
// lies inside its own cell, so none is ever cut at a cell face.
float layer(vec3 dir, float cells, float share, float size) {
    vec3 p = dir * cells;
    vec3 c = floor(p);
    if (hash(c) > share) return 0.0;
    vec3 star = normalize(c + 0.25 + 0.5 * vec3(hash(c + 11.0), hash(c + 23.0), hash(c + 37.0))) * cells;
    vec3 in_cell = star - c;
    if (any(lessThan(in_cell, vec3(size))) || any(greaterThan(in_cell, vec3(1.0 - size)))) return 0.0;
    float glow = 1.0 - smoothstep(0.0, size, length(p - star));
    float b = dimmest + (1.0 - dimmest) * hash(c + 53.0);
    float t = hash(c + 71.0);
    if (t < twinkle_share) b *= 1.0 - twinkle_depth * (0.5 + 0.5 * sin(time * (1.0 + 2.0 * t / twinkle_share) + twinkle_phases * t));
    return glow * b;
}

void main() {
#ifdef SKY_OFF
    FRAG = vec4(0.0, 0.0, 0.0, 1.0);
#else
    vec2 xy = gl_FragCoord.xy / resolution * 2.0 - 1.0;
    vec3 dir = normalize(fwd + xy.x * right + xy.y * up);
    float s = fine_gain * layer(dir, fine_cells, fine_share, fine_size) + big_gain * layer(dir, big_cells, big_share, big_size);
    FRAG = vec4(tint * s, 1.0);
#endif
}
