#version 100
// One direction of a 9-tap Gaussian blur, for bloom (main.zig: glowPass).
// `tap` is the offset between taps in texture coordinates: along x or y.
// WebGL 1 (GLSL ES 1.00); blur.330.fs is the same for desktop.
precision mediump float;
varying vec2 fragTexCoord;
varying vec4 fragColor;
uniform sampler2D texture0;
uniform vec2 tap;

const float w0 = 0.227027;
const float w1 = 0.1945946;
const float w2 = 0.1216216;
const float w3 = 0.054054;
const float w4 = 0.016216;

void main() {
    vec3 c = texture2D(texture0, fragTexCoord).rgb * w0;
    c += (texture2D(texture0, fragTexCoord + tap).rgb + texture2D(texture0, fragTexCoord - tap).rgb) * w1;
    c += (texture2D(texture0, fragTexCoord + 2.0 * tap).rgb + texture2D(texture0, fragTexCoord - 2.0 * tap).rgb) * w2;
    c += (texture2D(texture0, fragTexCoord + 3.0 * tap).rgb + texture2D(texture0, fragTexCoord - 3.0 * tap).rgb) * w3;
    c += (texture2D(texture0, fragTexCoord + 4.0 * tap).rgb + texture2D(texture0, fragTexCoord - 4.0 * tap).rgb) * w4;
    gl_FragColor = vec4(c, 1.0);
}
