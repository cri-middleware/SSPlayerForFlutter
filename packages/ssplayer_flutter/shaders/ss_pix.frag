#version 460 core
#include "ss_shader_common.glsl"

// ss-pix — mosaic: snap the sample to a block grid. param0 = fPower, the block
// edge in texels (1 + 96·power).
void main() {
  SS_SETUP();
  float fPower = ss_param0;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float v = 1.0 + 96.0 * fPower;
  vec2 step_uv = vec2(v * px.x, v * px.y);
  vec2 Coord = floor(vUV / step_uv) * step_uv;
  vec4 Pixel = ssTex(Coord);
  fragColor = ssFinish(Pixel);
}
