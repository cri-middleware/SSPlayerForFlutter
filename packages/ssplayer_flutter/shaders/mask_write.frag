#version 460 core
#include <flutter/runtime_effect.glsl>

// Mask coverage writer for a single sprite quad (SpriteStudio mask §3-2-1).
//
// One writer = one bit of the coverage bitmap. The bit is pre-encoded on the CPU
// into the R/G/B channel that owns it (8 bits x 3 = 24 writers; alpha is left as
// the "any coverage" accumulator), and the quad is drawn with BlendMode.plus, so
// the disjoint per-writer bits OR together losslessly.
//
// UV reconstruction is the same trick as partcolor.frag: Flutter fragment
// shaders get no per-vertex varyings, so the quad-local (s,t) is recovered from
// the fragment position via a CPU-supplied inverse affine and the corner UVs are
// interpolated analytically. Coordinates are player-local — the coverage canvas
// is set up so its local space IS the player's (mask.dart / MaskPlan.bounds).
//
// Uniform float indices (samplers are NOT counted) are written by
// internal_player.dart in this exact declaration order — keep them in sync.

uniform vec2 uOrigin;   // 0 : LT world corner (origin of the frag-space affine)
uniform vec4 uInv;      // 1 : 2x2 inverse affine [m00,m01,m10,m11], frag -> (s,t)
uniform vec2 uTexSize;  // 2 : texture size in pixels (w,h)
uniform vec4 uUvA;      // 3 : (LT.uv, RT.uv) in texture pixels
uniform vec4 uUvB;      // 4 : (LB.uv, RB.uv) in texture pixels
uniform vec4 uBit;      // 5 : rgb = this writer's bit colour, a = cutout threshold
uniform sampler2D uTex; // sampler 0

out vec4 fragColor;

void main() {
  vec2 d = FlutterFragCoord().xy - uOrigin;
  float s = clamp(uInv.x * d.x + uInv.y * d.y, 0.0, 1.0);
  float t = clamp(uInv.z * d.x + uInv.w * d.y, 0.0, 1.0);

  vec2 uvpx = mix(mix(uUvA.xy, uUvA.zw, s), mix(uUvB.xy, uUvB.zw, s), t);

  // §2-5 cutout: only texels above the threshold contribute coverage.
  // threshold = (255 - mask) / 255, so mask == 255 writes every non-transparent
  // texel and mask == 0 writes nothing (the writer is dropped on the CPU anyway).
  // A negative threshold means "no cutout" (a textureless Shape writer: the
  // geometry itself is the mask).
  //
  // Runtime effects may not `discard`; under BlendMode.plus a fully transparent
  // fragment adds nothing, which is exactly what a discard would achieve.
  if (uBit.a >= 0.0 && texture(uTex, uvpx / uTexSize).a <= uBit.a) {
    fragColor = vec4(0.0);
    return;
  }

  // BlendMode.plus is premultiplied, so the bit must be written with alpha 1 or
  // it would be scaled away.
  fragColor = vec4(uBit.rgb, 1.0);
}
