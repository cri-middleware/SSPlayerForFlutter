#version 460 core
#include "ss_shader_common.glsl"

// ss-scatter — displace a random subset of texels in a random direction.
// param0 = displacement, param1 = affected fraction, param2 = phase seed.

float ss_scatter_rand(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  SS_SETUP();
  float fPower = ss_param0;
  float fRatio = ss_param1;
  float fPhase = ss_param2;
  vec2 Coord = vUV;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 u = floor(Coord / px) * px;
  vec2 t = u + vec2(fPhase);
  float r = ss_scatter_rand(t) * PI * 2.0 - PI;
  float r2 = step(ss_scatter_rand(t * r), fRatio);
  vec2 v = vec2(sin(r), cos(r)) * px * 96.0 * fPower * r2;
  vec4 Pixel = ssTex(Coord + v);
  fragColor = ssFinish(Pixel);
}
