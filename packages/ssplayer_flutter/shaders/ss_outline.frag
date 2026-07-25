#version 460 core
#include "ss_shader_common.glsl"

// ss-outline — keep only the texels whose 4-neighbourhood straddles the alpha
// edge, so the cell reduces to its silhouette. param0 = alpha threshold.
void main() {
  SS_SETUP();
  float fThreshold = ss_param0;
  float fRatio = abs(fThreshold);
  float e = 1.0e-5;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float lo = 0.0;
  lo += step(ssTex(vUV + vec2(-px.x, 0.0)).a, fRatio);
  lo += step(ssTex(vUV + vec2(px.x, 0.0)).a, fRatio);
  lo += step(ssTex(vUV + vec2(0.0, -px.y)).a, fRatio);
  lo += step(ssTex(vUV + vec2(0.0, px.y)).a, fRatio);
  vec4 center = ssTex(vUV);
  float hi = step(fRatio + e, center.a);
  float v = min(hi * lo, 1.0);
  if (v <= 0.0) SS_DISCARD();
  fragColor = ssFinish(vec4(vec3(v), v));
}
