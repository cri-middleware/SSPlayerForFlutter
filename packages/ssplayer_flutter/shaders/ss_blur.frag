#version 460 core
#include "ss_shader_common.glsl"

// ss-blur — 9-tap box blur. param0 = fFocus, the tap spacing in texels (×16).
//
// The ONE effect that does not fold the PartColor formula: it multiplies by the
// part colour instead of compositing through `ssBlend`, mirroring the SS6
// reference (and both sibling ports). `uCoef`/`uRate` are therefore unread here
// — they keep their uniform slots regardless, so the shared writer still works.
void main() {
  SS_SETUP();
  float fFocus = ss_param0;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 d = vec2(fFocus * px.x * 16.0, fFocus * px.y * 16.0);
  vec2 tc = vUV;
  vec4 sum = ssTex(tc);
  sum += ssTex(vec2(tc.x + d.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x + d.x, tc.y));
  sum += ssTex(vec2(tc.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y - d.y));
  sum += ssTex(vec2(tc.x + d.x, tc.y - d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y));
  sum += ssTex(vec2(tc.x, tc.y - d.y));
  vec4 Pixel = sum / 9.0;
  vec4 c = Pixel * vColor;
  fragColor = vec4(c.rgb * c.a, c.a); // premultiplied output
}
