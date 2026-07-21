#version 460 core

// Flutter GPU PartColor (§10) + mask-replay (§9) vertex shader.
//
// A whole RUN of peeled parts is drawn in ONE batched call (the fan-out collapse
// §perf): each vertex carries [a_part] — the index of its part within the run —
// and the fragment reads that part's corner colours / rate / coef / mask sets
// from the PartColorInfo uniform array. quad-local (s,t) and the player-local
// position (for the mask UV) are `out` varyings — no per-fragment affine
// reconstruction like the dart:ui runtime-effect shaders.
//
// Per-vertex (one quad = 4 corners lt,rt,lb,rb):
//   loc 0  a_position (vec2)  player-local (world-transformed) corner XY
//   loc 1  a_uv       (vec2)  normalised texture UV for the corner
//   loc 2  a_st       (vec2)  quad-local coord: lt(0,0) rt(1,0) lb(0,1) rb(1,1)
//   loc 3  a_part     (float) index of this part within the batched run
in vec2 a_position;
in vec2 a_uv;
in vec2 a_st;
in float a_part;

uniform FrameInfo {
  mat4 mvp; // player-local -> NDC (same as the sprite pipeline)
} frame_info;

out vec2 v_local; // player-local position (mask UV samples in this space)
out vec2 v_uv;    // affine over the quad -> exact
out vec2 v_st;    // the fragment reconstructs true bilinear from this
flat out float v_part; // integer varyings aren't reflectable; carry as float

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_local = a_position;
  v_uv = a_uv;
  v_st = a_st;
  v_part = a_part;
}
