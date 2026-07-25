#version 460 core
#include "ss_shader_common.glsl"

// ss-circle — polar-unwrap the cell into a disc (radius = cell height, angle =
// cell width). param0 = phase, param1 = direction (≤ 0 reverses).
//
// Needs the cell's UV rect: the disc is centred on the cell, not the atlas.
// Fragments outside the disc are cut out.
void main() {
  SS_SETUP();
  float fPhase = ss_param0;
  float fDirection = ss_param1;
  float e = 1.0e-10;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 uv1 = vec2(px.x + e, px.y + e);
  vec2 lt_uv = ss_cell_rect.xy;
  vec2 rb_uv = ss_cell_rect.zw;
  vec2 center_uv = (lt_uv + rb_uv) * 0.5;
  vec2 tx = vUV / uv1;
  vec2 c = center_uv / uv1;
  vec2 lt = lt_uv / uv1;
  vec2 rb = rb_uv / uv1;
  vec2 dd = rb - lt;
  vec2 v = tx - c;
  float r = min(abs(rb.x - c.x), abs(rb.y - c.y)) + e;
  float dis = length(v);
  if (dis > r) SS_DISCARD();
  vec2 nv = (dis > e) ? (v / dis) : vec2(1.0, 0.0);
  float uu = 1.0 - dis / r;
  float vv = (atan(nv.y, nv.x) / PI + 1.0) * 0.5 + fPhase;
  if (vv < 0.0) vv += 1.0;
  if (vv > 1.0) vv -= 1.0;
  if (fDirection <= 0.0) vv = 1.0 - vv;
  vec2 st = dd * vec2(uu, vv) * uv1;
  vec4 Pixel = ssTex(lt_uv + st);
  fragColor = ssFinish(Pixel);
}
