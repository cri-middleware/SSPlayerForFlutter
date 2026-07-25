#version 460 core
#include "ss_shader_common.glsl"

// ss-step — posterise the texel's brightness. param0 = threshold (its sign picks
// the polarity), param1 = stage count, param2 = monochrome (0) ↔ keep rgb (1).
void main() {
  SS_SETUP();
  float fThreshold = ss_param0;
  float fStage = ss_param1;
  float fColor = ss_param2;
  vec4 Pixel = ssTex(vUV);
  float d = 1.0 + 255.0 * abs(fStage);
  float e = 1.0e-10;
  float t = abs(fThreshold);
  float b = abs(step(fThreshold, 0.0) - max(Pixel.r, max(Pixel.g, Pixel.b)));
  float r = clamp(floor((b - t) / (t + e) * 256.0 / d) * d / 256.0, 0.0, 1.0);
  float c = step(t, b) * r;
  vec3 v = mix(vec3(c), Pixel.rgb * c, fColor);
  fragColor = ssFinish(vec4(v, Pixel.a));
}
