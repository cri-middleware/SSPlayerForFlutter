#version 460 core

// Flutter GPU masked-Shape vertex shader (§9 target that is a §11 Shape). A Shape
// carries its colour in its vertices (per-vertex gradient), so this only forwards
// the colour and the player-local position (for the mask UV); the fragment gates
// on the coverage. A Shape samples no texture, so the vertex is `[pos, rgba]`
// (6 floats — no UV, which impellerc would strip and then fail to reflect).
in vec2 a_position;
in vec4 a_color;

uniform FrameInfo {
  mat4 mvp;
} frame_info;

out vec2 v_local;
out vec4 v_color;

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_local = a_position;
  v_color = a_color;
}
