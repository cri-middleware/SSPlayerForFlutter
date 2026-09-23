#version 460 core

// Flutter GPU vertex stage for the SpriteStudio integration shaders (`ss-*`).
//
// A cut-down `partcolor.vert`: a shader part is drawn on its OWN quad (its
// parameters are a per-part uniform block, so there is nothing to batch), which
// means the mask-replay attributes that pipeline carries are not needed here —
// shader × mask is not combined (a masked part drops its shader and takes the
// plain masked path, as in both sibling ports).
//
// The four corner colours still ride on the four corner vertices so the
// rasteriser interpolates the PartColor gradient for free, with the blend
// rate in `a_coef.w` (it varies per corner too).
//
// vec4 vertex attributes MUST sit on a 16-byte boundary or Impeller misreads
// them (the ShapeMask alignment trap), so the layout is a 48-byte (12-float)
// stride with every vec4 at a 16-aligned offset — and 48 is itself a multiple of
// 16, so the alignment recurs on every vertex.
//   loc 0  a_position (vec2)  float 0   world-transformed corner XY
//   loc 1  a_uv       (vec2)  float 2   normalised texture UV
//   loc 2  a_color    (vec4)  float 4   this corner's straight RGBA
//   loc 3  a_coef     (vec4)  float 8   (coef.x, coef.y, coef.z, rate)
in vec2 a_position;
in vec2 a_uv;
in vec4 a_color;
in vec4 a_coef;

uniform FrameInfo {
  mat4 mvp; // player-local -> NDC (same as the sprite pipeline)
} frame_info;

out vec2 v_uv;
out vec4 v_color; // interpolated straight corner colour (the 4-corner gradient)
out vec4 v_coef;  // coef.xyz constant across the part, .w = interpolated rate

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
  v_color = a_color;
  v_coef = a_coef;
}
