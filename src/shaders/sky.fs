// Background starfield (main.zig: drawSky): a sky sphere of hashed stars that
// turns with the camera. main.zig prepends a header per GLSL version
// (#version, precision, FRAG) and draws it additively over the background.
// A pixel's view ray is `fwd` + x·`right` + y·`up`, x and y in -1..1 across
// the screen (main.zig scales right and up by the field of view).
uniform vec2 resolution;
uniform vec3 fwd;
uniform vec3 right;
uniform vec3 up;
uniform float time;

const vec3 tint = vec3(0.78, 0.84, 0.95); // cool white
const float twinkle_share = 0.3; // of the stars twinkle
const float twinkle_depth = 0.45; // dimmest twinkle, as a fraction off

// Pseudo-random 0..1 per integer cell (needs highp: cells reach ~100).
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1) * 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// One layer: the sphere cut into `cells` cubes per unit; a `share` of them hold
// a star of angular radius `size` (cube widths), kept off the cube's faces so
// it is rarely clipped.
float layer(vec3 dir, float cells, float share, float size) {
    vec3 p = dir * cells;
    vec3 c = floor(p);
    if (hash(c) > share) return 0.0;
    vec3 star = normalize(c + 0.25 + 0.5 * vec3(hash(c + 11.0), hash(c + 23.0), hash(c + 37.0))) * cells;
    float glow = 1.0 - smoothstep(0.0, size, length(p - star));
    float b = 0.35 + 0.65 * hash(c + 53.0);
    float t = hash(c + 71.0);
    if (t < twinkle_share) b *= 1.0 - twinkle_depth * (0.5 + 0.5 * sin(time * (1.0 + 2.0 * t / twinkle_share) + 40.0 * t));
    return glow * b;
}

void main() {
    vec2 xy = gl_FragCoord.xy / resolution * 2.0 - 1.0;
    vec3 dir = normalize(fwd + xy.x * right + xy.y * up);
    float s = 0.55 * layer(dir, 90.0, 0.05, 0.22) + layer(dir, 35.0, 0.03, 0.12);
    FRAG = vec4(tint * s, 1.0);
}
