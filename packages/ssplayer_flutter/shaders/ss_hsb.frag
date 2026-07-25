#version 460 core
#include "ss_shader_common.glsl"

// ss-hsb — shift the texel in HSB space. param0 = hue rotation (wraps),
// param1 = saturation offset, param2 = brightness offset (both clamped).

vec4 ss_rgb_to_hsb(vec4 color) {
  vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  vec4 p = mix(vec4(color.bg, K.wz), vec4(color.gb, K.xy), step(color.b, color.g));
  vec4 q = mix(vec4(p.xyw, color.r), vec4(color.r, p.yzx), step(p.x, color.r));
  float d = q.x - min(q.w, q.y);
  float e = 1.0e-10;
  return vec4(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x, color.a);
}

vec4 ss_hsb_to_rgb(vec4 hsb) {
  vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
  vec3 p = abs(fract(hsb.xxx + K.xyz) * 6.0 - K.www);
  return vec4(hsb.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), hsb.y), hsb.w);
}

void main() {
  SS_SETUP();
  float fHue = ss_param0;
  float fSaturation = ss_param1;
  float fBrightness = ss_param2;
  vec4 Pixel = ssTex(vUV);
  vec4 hsb = ss_rgb_to_hsb(Pixel);
  hsb.x += fHue;
  hsb.y = clamp(hsb.y + fSaturation, 0.0, 1.0);
  hsb.z = clamp(hsb.z + fBrightness, 0.0, 1.0);
  if (hsb.x < 0.0) hsb.x += 1.0;
  if (hsb.x > 1.0) hsb.x -= 1.0;
  vec4 shifted = ss_hsb_to_rgb(hsb);
  fragColor = ssFinish(vec4(shifted.rgb, shifted.a));
}
