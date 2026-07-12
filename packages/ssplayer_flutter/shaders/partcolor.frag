#version 460 core
#include <flutter/runtime_effect.glsl>

// PartColor blend for a single Normal sprite quad (SpriteStudio parts_color §1-4).
//
// Flutter fragment shaders cannot declare custom per-vertex varyings, so the
// per-vertex `CUSTOM0` packing the Godot/Web ports use does not port. Instead
// each PartColored part is drawn on its OWN quad and the per-corner colour / rate
// / UV gradient is reconstructed analytically here:
//
//   FlutterFragCoord()  --(CPU affine uInv)-->  quad-local (s,t) in [0,1]^2
//   bilinear over the four corners  ->  colour, rate, texture-pixel UV
//
// The world quad of a non-deformed sprite is an affine image of the unit square,
// so the inverse map is affine and the reconstruction is exact.
//
// Uniform float indices (the sampler is NOT counted) are written by
// internal_player.dart in this exact declaration order — keep them in sync.

uniform vec2 uOrigin;   // 0  : LT world corner (origin of the frag-space affine)
uniform vec4 uInv;      // 1  : 2x2 inverse affine [m00,m01,m10,m11], frag -> (s,t)
uniform vec2 uTexSize;  // 2  : texture size in pixels (w,h)
uniform vec4 uCoef;     // 3  : PartColor coefficient row (fSrc, fDst, fDstSrc, 0)
uniform vec4 uRate;     // 4  : corner blend rates (LT, RT, LB, RB)
uniform vec4 uColLT;    // 5  : LT straight-alpha rgba (0..1)
uniform vec4 uColRT;    // 6  : RT straight-alpha rgba
uniform vec4 uColLB;    // 7  : LB straight-alpha rgba
uniform vec4 uColRB;    // 8  : RB straight-alpha rgba
uniform vec4 uUvA;      // 9  : (LT.uv, RT.uv) in texture pixels
uniform vec4 uUvB;      // 10 : (LB.uv, RB.uv) in texture pixels
uniform sampler2D uTex; // sampler 0

out vec4 fragColor;

void main() {
  // Fragment position in the same space as the quad's vertex positions.
  vec2 d = FlutterFragCoord().xy - uOrigin;
  // Quad-local coordinates in [0,1]^2. The clamp is a guard for edge fragments;
  // interior fragments already resolve inside the unit square.
  float s = clamp(uInv.x * d.x + uInv.y * d.y, 0.0, 1.0);
  float t = clamp(uInv.z * d.x + uInv.w * d.y, 0.0, 1.0);

  // Bilinear over the four corners (top = LT..RT, bottom = LB..RB).
  vec4 col = mix(mix(uColLT, uColRT, s), mix(uColLB, uColRB, s), t);
  float rate = mix(mix(uRate.x, uRate.y, s), mix(uRate.z, uRate.w, s), t);
  vec2 uvpx =
      mix(mix(uUvA.xy, uUvA.zw, s), mix(uUvB.xy, uUvB.zw, s), t);
  vec2 uv = uvpx / uTexSize;

  // Sampled texel is premultiplied (engine convention); recover straight rgb for
  // the parts_color formula, which composites straight texel and part colours.
  vec4 tex = texture(uTex, uv);
  vec3 pixel = tex.a > 0.0 ? tex.rgb / tex.a : tex.rgb;

  // varg = (1 + fSrc*rate, fDst*rate, fDstSrc, _): one branch-free formula for
  // Mix / Mul / Add / Sub. rate == 0 collapses this to `pixel` (texel passthrough).
  float vx = 1.0 + uCoef.x * rate;
  float vy = uCoef.y * rate;
  float vz = uCoef.z;
  vec3 rgb = pixel * vx + mix(vec3(1.0), pixel, vz) * col.rgb * vy;
  rgb = clamp(rgb, 0.0, 1.0);

  // color.a already carries the part's hierarchical alpha (pre-folded by the
  // Brain); do not re-multiply PartState.alpha here.
  float a = tex.a * col.a;

  // Flutter expects a premultiplied fragment output.
  fragColor = vec4(rgb * a, a);
}
