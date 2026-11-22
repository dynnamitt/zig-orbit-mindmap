// Planet vertex shader (main.zig: drawPlanet). main.zig prepends a header per
// GLSL version declaring vertexPosition/vertexNormal and the fragPos/
// fragNormal outputs. raylib binds those attributes and sets mvp and matModel
// by name in drawMesh.
uniform mat4 mvp;
uniform mat4 matModel;

void main() {
    fragPos = (matModel * vec4(vertexPosition, 1.0)).xyz;
    // Planets are scaled uniformly, so the model matrix keeps normals' direction.
    fragNormal = (matModel * vec4(vertexNormal, 0.0)).xyz;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
