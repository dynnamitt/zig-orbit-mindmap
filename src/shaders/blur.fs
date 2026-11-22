// One direction of a 9-tap Gaussian blur, for bloom (main.zig: glowPass).
// main.zig prepends a header per GLSL version: #version, the fragTexCoord
// input, and TEX/FRAG for the texture lookup and output. `tap` is the offset
// between taps in texture coordinates, along x or y; taps may fall between
// texels (bilinear filtering).
uniform sampler2D texture0;
uniform vec2 tap;

const float w0 = 0.227027;
const float w1 = 0.1945946;
const float w2 = 0.1216216;
const float w3 = 0.054054;
const float w4 = 0.016216;

void main() {
    vec3 c = TEX(texture0, fragTexCoord).rgb * w0;
    c += (TEX(texture0, fragTexCoord + tap).rgb + TEX(texture0, fragTexCoord - tap).rgb) * w1;
    c += (TEX(texture0, fragTexCoord + 2.0 * tap).rgb + TEX(texture0, fragTexCoord - 2.0 * tap).rgb) * w2;
    c += (TEX(texture0, fragTexCoord + 3.0 * tap).rgb + TEX(texture0, fragTexCoord - 3.0 * tap).rgb) * w3;
    c += (TEX(texture0, fragTexCoord + 4.0 * tap).rgb + TEX(texture0, fragTexCoord - 4.0 * tap).rgb) * w4;
    FRAG = vec4(c, 1.0);
}
