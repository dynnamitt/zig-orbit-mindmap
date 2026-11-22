// Planet fragment shader: lit by every star, brighter on the sides facing
// them. main.zig prepends a header per GLSL version (fragPos/fragNormal
// inputs, FRAG output, MAX_STARS) and sets the uniforms each frame.
uniform vec4 colDiffuse; // the planet's colour (raylib: material diffuse)
uniform int starCount;
uniform vec3 starPos[MAX_STARS];
uniform vec3 starLight[MAX_STARS]; // star colour × its share of the light
uniform float ambient;

void main() {
    vec3 n = normalize(fragNormal);
    vec3 light = vec3(ambient);
    // GLSL ES 1.00 needs a constant loop bound: stop at starCount.
    for (int i = 0; i < MAX_STARS; i++) {
        if (i >= starCount) break;
        light += starLight[i] * max(dot(n, normalize(starPos[i] - fragPos)), 0.0);
    }
    FRAG = vec4(colDiffuse.rgb * light, colDiffuse.a);
}
