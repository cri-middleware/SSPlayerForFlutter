#version 460 core
#include <flutter/runtime_effect.glsl>

// PartColor blend + mask replay for a single Normal sprite quad.
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
// This is also the path for **masked** parts, PartColored or not: a part with no
// PartColor passes white corners with rate 0, which the formula below collapses
// to a plain texel passthrough (default white, rate 0 = passthrough). Masking
// a part therefore costs it the batched drawVertices fast path — the same per-part
// cliff the flagship has.
//
// Uniform float indices (samplers are NOT counted) are written by
// canvas_backend.dart (_setPartColorUniforms) in this exact declaration order —
// keep them in sync.

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
uniform vec4 uMaskBits; // 11 : (incrementSet, invertSet, visibleInside, enabled)
uniform vec4 uMaskUv;   // 12 : player-local -> coverage UV basis [m00,m01,m10,m11]
uniform vec2 uMaskOff;  // 13 : offset half of that affine
uniform sampler2D uTex;      // sampler 0
uniform sampler2D uCoverage; // sampler 1 (1x1 transparent dummy when unmasked)

out vec4 fragColor;

// Flutter's runtime effects forbid integer bitwise operators, so every bit test
// below is float arithmetic. Bit `i` of `set` (a 24-bit integer carried exactly
// in a float32 mantissa) where `p == 2^i`:
float bitAt(float set, float p) {
  return floor(mod(set / p, 2.0));
}

// Mask replay: rebuild the SS stencil for this fragment from the
// coverage bitmap and decide whether the fragment survives.
//
// Unlike the flagship we do NOT carry a `mask_meta[]` array: scope is
// resolved on the CPU into two 24-bit sets — one per OP, which is exactly the
// plane split, handed to us for free.
bool maskPasses(vec2 local) {
  if (uMaskBits.w < 0.5) return true; // not masked this frame

  vec2 muv = vec2(uMaskUv.x * local.x + uMaskUv.y * local.y,
                  uMaskUv.z * local.x + uMaskUv.w * local.y) + uMaskOff;
  bool visibleInside = uMaskBits.z > 0.5;

  // The bitmap only spans the writers' bbox; a fragment outside it is covered by
  // no writer. Bailing here also avoids the edge-clamp smearing an edge writer's
  // bits across everything beyond the box.
  if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0) {
    return !visibleInside;
  }

  // Decode the three bit-carrying channels into one exact 24-bit value.
  vec4 cov = texture(uCoverage, muv);
  float bits = floor(cov.r * 255.0 + 0.5)
             + floor(cov.g * 255.0 + 0.5) * 256.0
             + floor(cov.b * 255.0 + 0.5) * 65536.0;

  // `Invert` and `IncrementWrap` are each their own inverse alone, but
  // they do NOT commute, so replaying both into one accumulator would make
  // coverage depend on the order the writers happen to be walked in (`incr then
  // invert` lands on 254 = covered where `invert then incr` wraps back to 0 =
  // not covered). A stencil buffer keeps them apart by giving each OP its own
  // WriteMask; replaying in a shader, separate accumulators do the same job with
  // no bit budget to divide — so the counter has no overlap ceiling here (it is
  // 7 for ForUnity under URP).
  float parity = 0.0; // invert writers: covered where an ODD number overlap
  float count = 0.0;  // increment writers: covered where ANY overlap
  float p = 1.0; // 2^i
  for (int i = 0; i < 24; i++) {
    if (bitAt(bits, p) > 0.5) {
      // A writer in neither set is out of this target's scope — skip it.
      if (bitAt(uMaskBits.y, p) > 0.5) {
        parity = 1.0 - parity; // invert (parity plane)
      } else if (bitAt(uMaskBits.x, p) > 0.5) {
        count += 1.0;          // increment (counter plane)
      }
    }
    p *= 2.0;
  }

  // The union of the two planes — what SpriteStudio specifies where writers of
  // differing mask_influence overlap.
  bool masked = parity > 0.5 || count > 0.5;
  // Polarity is the target's, not the writer's.
  return masked == visibleInside;
}

void main() {
  // Fragment position in the same space as the quad's vertex positions.
  vec2 frag = FlutterFragCoord().xy;

  // Runtime effects may not `discard`; a fully transparent fragment is the
  // equivalent — it is a no-op under every blend mode we emit (Mix / Add /
  // Mul / Sub all leave the destination untouched for a zero premultiplied src).
  if (!maskPasses(frag)) {
    fragColor = vec4(0.0);
    return;
  }

  vec2 d = frag - uOrigin;
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
