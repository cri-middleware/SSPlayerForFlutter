#version 460 core

// Flutter GPU mask coverage-writer vertex shader. Runs in the coverage
// pre-pass, whose render target is sized to the writers' bbox; [mvp] maps
// player-local space into that target's NDC (built from the same uvBasis/uvOffset
// the main-pass shader samples the coverage with, so the two agree exactly).
//
// One vertex format for every writer kind: a Sprite writer passes its quad (with
// UVs for the texel cutout); a Shape/Mesh writer passes its polygon/mesh
// triangles (the geometry itself is the mask, so UV is unused — 0).
in vec2 a_position;
in vec2 a_uv;

uniform MaskFrame {
  mat4 mvp; // player-local -> coverage-target NDC
} mask_frame;

out vec2 v_uv;

void main() {
  gl_Position = mask_frame.mvp * vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
}
