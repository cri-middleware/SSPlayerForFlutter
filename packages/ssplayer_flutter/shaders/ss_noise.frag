#version 460 core
#include "ss_shader_common.glsl"

// ss-noise — blend static into the texel. param0 = mix amount, param1 = chroma
// (0 = monochrome noise), param2 = phase seed (animate it to make it crawl).

float ss_noise_rand(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  SS_SETUP();
  float fPower = ss_param0;
  float fColor = ss_param1;
  float fPhase = ss_param2;
  vec2 Coord = vUV;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 u = floor(Coord / px) * px;
  vec4 Pixel = ssTex(Coord);
  vec2 t = u + vec2(fPhase);
  vec3 c;
  c.r = ss_noise_rand(t);
  c.g = mix(c.r, ss_noise_rand(t * c.r), fColor);
  c.b = mix(c.g, ss_noise_rand(t * c.g), fColor);
  Pixel.rgb = clamp(mix(Pixel.rgb, c.rgb, fPower), 0.0, 1.0);
  fragColor = ssFinish(Pixel);
}
