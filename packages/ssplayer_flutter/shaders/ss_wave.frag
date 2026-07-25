#version 460 core
#include "ss_shader_common.glsl"

// ss-wave — sine-displace each row horizontally. param0 = frequency,
// param1 = amplitude, param2 = phase.
void main() {
  SS_SETUP();
  float fWidth = ss_param0;
  float fHeight = ss_param1;
  float fPhase = ss_param2;
  vec2 Coord = vUV;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float l = 384.0 * fHeight * 0.5;
  float s = l * sin(Coord.y * 384.0 * fWidth * 0.5 + PI * 2.0 * fPhase) * px.x;
  vec4 Pixel = ssTex(vec2(Coord.x + s, Coord.y));
  fragColor = ssFinish(Pixel);
}
