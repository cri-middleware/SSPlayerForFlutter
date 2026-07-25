#version 460 core
#include "ss_shader_common.glsl"

// ss-spot — radial spotlight over the cell. param0 = radius, param1 = falloff
// shape (inverse-square ↔ linear), param2 = white (0) ↔ the texel's own rgb (1).
//
// Needs the cell's UV rect: the light is centred on the cell, not the atlas.
void main() {
  SS_SETUP();
  float fPower = ss_param0;
  float fDecay = ss_param1;
  float fColor = ss_param2;
  float e = 1.0e-10;
  float p = abs(fPower);
  float d_abs = abs(fDecay);
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 uv1 = vec2(px.x + e, px.y + e);
  vec2 lt_uv = ss_cell_rect.xy;
  vec2 rb_uv = ss_cell_rect.zw;
  vec2 center_uv = (lt_uv + rb_uv) * 0.5;
  vec2 c = center_uv / uv1;
  vec2 rb = rb_uv / uv1;
  float l = min(abs(rb.x - c.x), abs(rb.y - c.y)) + e;
  vec2 t = vUV / uv1;
  vec2 v = c - t;
  float fR = max(p / (length(v / l) + e) - p, 0.0);
  float fL = max(p - length(v / l), 0.0);
  fR = clamp(mix(fR, fL, d_abs), 0.0, 1.0);
  vec3 sampled = ssTex(vUV).rgb;
  vec4 Pixel = vec4(mix(vec3(1.0), sampled, fColor), fR);
  fragColor = ssFinish(Pixel);
}
