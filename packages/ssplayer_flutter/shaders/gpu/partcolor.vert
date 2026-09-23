#version 460 core

// Flutter GPU PartColor + mask-replay vertex shader — the per-vertex
// attribute design shared with the Godot / Web siblings. Every per-part
// value (the four corner colours, the blend rate/coef, and the mask replay sets)
// is a vertex attribute, so a whole RUN of peeled parts batches into ONE draw
// (the fan-out collapse). A per-vertex attribute is also what keeps Impeller/
// Metal correct here: there is no dynamically-indexed uniform array, the one
// construct it miscompiles (`u[dynamicIndex + const]` reads 0).
//
// The four corner colours ride on the four corner vertices, so the rasteriser
// interpolates the gradient for free (no per-fragment bilinear); the blend
// rate rides in `a_coef.w` (also interpolated: rate varies per corner). The mask
// sets are constant across a part's 4 corners and are carried `flat`.
//
// vec4 vertex attributes MUST sit on a 16-byte boundary or Impeller misreads
// them (the ShapeMask alignment trap), so the layout is a 96-byte (24-float)
// stride with every vec4 at a 16-aligned offset. `a_mask_off` is a vec4 (only
// .xy used) so the stride stays a clean multiple of 16 and the alignment recurs
// on every vertex; its .xy feeds the mask UV, so it is a *used* attribute and
// impellerc keeps it (an unused one is stripped, breaking reflection).
//   loc 0  a_position (vec2)  float 0   world-transformed corner XY (= v_local)
//   loc 1  a_uv       (vec2)  float 2   normalised texture UV
//   loc 2  a_color    (vec4)  float 4   this corner's straight RGBA
//   loc 3  a_coef     (vec4)  float 8   (coef.x, coef.y, coef.z, rate)
//   loc 4  a_mask_bits(vec4)  float 12  (increment, invert, visibleInside, enabled)
//   loc 5  a_mask_uv  (vec4)  float 16  player-local -> coverage UV basis [m00,m01,m10,m11]
//   loc 6  a_mask_off (vec4)  float 20  (ox, oy, -, -)
in vec2 a_position;
in vec2 a_uv;
in vec4 a_color;
in vec4 a_coef;
in vec4 a_mask_bits;
in vec4 a_mask_uv;
in vec4 a_mask_off;

uniform FrameInfo {
  mat4 mvp; // player-local -> NDC (same as the sprite pipeline)
} frame_info;

out vec2 v_local; // player-local position (mask UV samples in this space)
out vec2 v_uv;
out vec4 v_color; // interpolated straight corner colour (the 4-corner gradient)
out vec4 v_coef;  // coef.xyz constant across the part, .w = interpolated rate
flat out vec4 v_mask_bits;
flat out vec4 v_mask_uv;
flat out vec4 v_mask_off;

void main() {
  gl_Position = frame_info.mvp * vec4(a_position, 0.0, 1.0);
  v_local = a_position;
  v_uv = a_uv;
  v_color = a_color;
  v_coef = a_coef;
  v_mask_bits = a_mask_bits;
  v_mask_uv = a_mask_uv;
  v_mask_off = a_mask_off;
}
