#version 460 core
#include "ss_shader_common.glsl"

// ss-sepia — tone the texel toward sepia, or to plain greyscale when the power
// is negative. param0 = fPower (strength; its sign picks sepia vs greyscale).
void main() {
  SS_SETUP();
  float fPower = ss_param0;
  vec4 Pixel = ssTex(vUV);
  float gray = dot(Pixel.rgb, vec3(0.298912, 0.586611, 0.114478));
  vec3 GrayRgb = vec3(gray);
  vec3 SepiaRgb = GrayRgb * vec3(1.07, 0.74, 0.43);
  vec3 toned = mix(SepiaRgb, GrayRgb, step(fPower, 0.0));
  vec3 mixed_rgb = mix(Pixel.rgb, toned, abs(fPower));
  fragColor = ssFinish(vec4(mixed_rgb, Pixel.a));
}
