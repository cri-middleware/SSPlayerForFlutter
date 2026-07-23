#version 460 core

// Flutter GPU masked-Shape vertex shader (§9 target that is a §11 Shape). A Shape
// carries its colour in its vertices (per-vertex gradient), so this only forwards
// the colour and the player-local position (for the mask UV); the fragment gates
// on the coverage.
//
// The vertex is `[a_position(vec2), a_local(vec2), a_color(vec4)]` = 8 floats,
// mirroring the working sprite pipeline's 3-attribute layout. A tighter
// 2-attribute `vec2 + vec4` (6-float) layout puts the `vec4` at byte offset 8,
// which Impeller misreads (it aligns a vertex `vec4` to offset 16) — the colour
// then picks up position bytes and clamps to white. The middle slot carries the
// player-local position AGAIN (the same value as `a_position`) so it aligns
// `a_color` to offset 16 *and* is genuinely used (`v_local`): a dummy unused
// attribute would be stripped by impellerc, breaking reflection.
in vec2 a_position;
in vec2 a_local;
in vec4 a_color;

uniform FrameInfo {
  mat4 mvp;
} frame_info;

out vec2 v_local;
out vec4 v_color;

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_local = a_local;
  v_color = a_color;
}
