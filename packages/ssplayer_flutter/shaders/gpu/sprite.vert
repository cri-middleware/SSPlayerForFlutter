#version 460 core

// Flutter GPU textured-sprite vertex shader (Normal / Mesh / Effect kinds).
//
// Unlike the dart:ui runtime-effect shaders (shaders/partcolor.frag etc.) this
// is real GLSL: per-vertex `in` attributes and `out` varyings are available, so
// the CPU-side FlutterFragCoord()->uInv affine reconstruction the Canvas path
// needs is unnecessary here — UV and colour interpolate for free.
//
// One tightly-packed interleaved vertex buffer, attributes in location order
// (the GeometryBuilder GPU bake writes them in exactly this order):
//   loc 0  a_position (vec2)  Normal/Shape: player-local XY (world matrix baked
//                             on CPU); Mesh/Effect: already world/sim-space XY.
//   loc 1  a_uv       (vec2)  normalised [0,1] texture coords (the Brain emits
//                             texture-pixel UVs; the bake divides by tex size).
//   loc 2  a_color    (vec4)  premultiplied RGBA vertex colour (white*alpha,
//                             particle colour*alpha, ...).
in vec2 a_position;
in vec2 a_uv;
in vec4 a_color;

uniform FrameInfo {
  // player-local -> NDC orthographic projection. SpriteStudio is coord-system 1
  // (Y-Down) and the Brain flips once; this matrix reproduces the plain Y-Down
  // Canvas placement WITHOUT adding a second flip (see FlutterGpuBackend).
  mat4 mvp;
} frame_info;

out vec2 v_uv;
out vec4 v_color;

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
  v_color = a_color;
}
