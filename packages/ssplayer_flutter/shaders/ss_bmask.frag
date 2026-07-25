#version 460 core
#include "ss_shader_common.glsl"

// ss-bmask — brightness key: cut out every texel at or below the key.
// param0 = fBrightness (its sign picks which side survives).
void main() {
  SS_SETUP();
  float fBrightness = ss_param0;
  vec4 Pixel = ssTex(vUV);
  float b = abs(step(fBrightness, 0.0) - max(Pixel.r, max(Pixel.g, Pixel.b)));
  if (b <= abs(fBrightness)) SS_DISCARD();
  fragColor = ssFinish(Pixel);
}
