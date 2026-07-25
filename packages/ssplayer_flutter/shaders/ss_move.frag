#version 460 core
#include "ss_shader_common.glsl"

// ss-move — directional smear (motion blur). param0 = distance (its sign flips
// the direction), param1 = angle in half-turns, param2 = decay per tap.
//
// The tap count is data-driven, but the loop bound must be a COMPILE-TIME
// constant (impellerc, like WebGL1, rejects a dynamic bound), so it is the
// clamp's own ceiling with a `break` inside — the form both siblings use too.
void main() {
  SS_SETUP();
  float fDistance = ss_param0;
  float fDirection = ss_param1;
  float fPower = ss_param2;
  vec2 Coord = vUV;
  vec2 px = TEXTURE_PIXEL_SIZE;
  int iCount = int(floor(abs(fDistance) * 96.0));
  if (iCount > 128) iCount = 128;
  vec2 Vel = vec2(sin(fDirection * PI) * px.x, cos(fDirection * PI) * px.y) *
      sign(fDistance);
  Coord += Vel * float(iCount);
  Coord -= Vel;
  vec4 Pixel = ssTex(Coord);
  for (int i = 1; i < 128; i++) {
    if (i >= iCount) break;
    Coord -= Vel;
    Pixel = mix(ssTex(Coord), Pixel, 0.96 * abs(fPower));
  }
  fragColor = ssFinish(Pixel);
}
