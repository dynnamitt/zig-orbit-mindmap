#version 330
// One direction of a 9-tap Gaussian blur, for bloom (main.zig: glowPass).
// `tap` is the offset between taps in texture coordinates: along x or y.
// Desktop (OpenGL 3.3); blur.100.fs is the same for WebGL.
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec2 tap;
out vec4 finalColor;

const float w0 = 0.227027;
const float w1 = 0.1945946;
const float w2 = 0.1216216;
const float w3 = 0.054054;
const float w4 = 0.016216;

void main() {
    vec3 c = texture(texture0, fragTexCoord).rgb * w0;
    c += (texture(texture0, fragTexCoord + tap).rgb + texture(texture0, fragTexCoord - tap).rgb) * w1;
    c += (texture(texture0, fragTexCoord + 2.0 * tap).rgb + texture(texture0, fragTexCoord - 2.0 * tap).rgb) * w2;
    c += (texture(texture0, fragTexCoord + 3.0 * tap).rgb + texture(texture0, fragTexCoord - 3.0 * tap).rgb) * w3;
    c += (texture(texture0, fragTexCoord + 4.0 * tap).rgb + texture(texture0, fragTexCoord - 4.0 * tap).rgb) * w4;
    finalColor = vec4(c, 1.0);
}
