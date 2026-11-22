// One direction of a Gaussian blur, for bloom (main.zig: glowPass). main.zig
// prepends a header per GLSL version: #version, the fragTexCoord input, and
// TEX/FRAG for the texture lookup and output. `tap` is the offset between
// taps in texture coordinates, along x or y.
uniform sampler2D texture0;
uniform vec2 tap;

// A 9-tap Gaussian in 5 lookups: bilinear filtering blends each pair of outer
// taps when sampled at their weight-averaged offset.
void main() {
    vec3 c = TEX(texture0, fragTexCoord).rgb * 0.2270270;
    c += (TEX(texture0, fragTexCoord + tap * 1.3846154).rgb + TEX(texture0, fragTexCoord - tap * 1.3846154).rgb) * 0.3162162;
    c += (TEX(texture0, fragTexCoord + tap * 3.2307692).rgb + TEX(texture0, fragTexCoord - tap * 3.2307692).rgb) * 0.0702703;
    FRAG = vec4(c, 1.0);
}
