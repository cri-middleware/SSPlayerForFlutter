// Shared preamble for the 13 built-in SpriteStudio integration shaders (`ss-*`)
// on the **Canvas** backend. Not a shader itself: every `shaders/ss_*.frag`
// `#include`s this right after its `#version` line, so all 13 share one uniform
// block, one UV/colour reconstruction and one PartColor tail.
//
// The include resolves because the Flutter shader build passes the shader's own
// directory to impellerc (`--include=<input.parent>`), the same mechanism
// `#include <flutter/runtime_effect.glsl>` below uses.
//
// ## Why the reconstruction exists
//
// Flutter fragment shaders take no custom per-vertex varyings, so the `vUV` /
// `vColor` / `vVarg` varyings the Godot & Web ports feed their `ss-*` bodies do
// not port. Instead each shader part is drawn on its OWN quad and those values
// are rebuilt analytically per fragment — the identical trick
// `shaders/partcolor.frag` uses for PartColor:
//
//   FlutterFragCoord()  --(CPU affine uInv)-->  quad-local (s,t) in [0,1]^2
//   bilinear over the four corners  ->  colour, rate, texture-pixel UV
//
// The world quad of a non-deformed sprite is an affine image of the unit square,
// so the inverse map is affine and the reconstruction is exact. `SS_SETUP()`
// declares and fills the locals the effect bodies read, which is what lets those
// bodies stay textually identical to the sibling ports' GLSL.
//
// ## Uniform layout
//
// Float uniform indices (samplers are NOT counted) are written by
// canvas_backend.dart (`_setSsShaderUniforms`) in this exact declaration
// order — keep them in sync. The order is shared by all 13 programs, which is
// what lets ONE writer serve them all: impellerc keeps a declared-but-unused
// uniform in the reflected layout (verified against both the Impeller runtime
// stage and the generated SkSL), so e.g. `uCellRect` still occupies its slot in
// the eleven effects that never sample it.

#include <flutter/runtime_effect.glsl>

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
uniform vec4 uParams;   // 11 : the SHDR attribute's param0..param3
uniform vec4 uCellRect; // 12 : cell UV rect (minU, minV, maxU, maxV), normalised
uniform sampler2D uTex; // sampler 0 (bilinear)

out vec4 fragColor;

const float PI = 3.141592653589793;

// The sibling ports' spellings, so the 13 effect bodies port verbatim.
#define ss_param0 uParams.x
#define ss_param1 uParams.y
#define ss_param2 uParams.z
#define ss_param3 uParams.w
#define ss_cell_rect uCellRect
#define TEXTURE_PIXEL_SIZE ssPx

// Declares this fragment's reconstructed locals and fills them. Every
// `ss_*.frag` opens `main()` with it; the names it introduces (`vUV`, `vColor`,
// `vRate`, `ssPx`) are the varyings the ported bodies expect.
//
// Locals rather than mutable globals: a runtime effect's uniform/global handling
// differs between the Impeller and SkSL paths, and out-parameters are the one
// form both accept without question.
#define SS_SETUP()                                       \
  vec2 vUV;                                              \
  vec4 vColor;                                           \
  float vRate;                                           \
  vec2 ssPx;                                             \
  ssSetup(vUV, vColor, vRate, ssPx)

// The ports' PartColor tail, bound to this fragment's reconstructed corner.
#define ssFinish(Pixel) ssBlend(Pixel, vColor, vRate)

// Runtime effects may not `discard`; a fully transparent fragment is the
// equivalent — it is a no-op under every blend mode we emit (Mix / Add / Mul /
// Sub all leave the destination untouched for a zero premultiplied source).
// Statement macro, so it is written `SS_DISCARD();` at the call site.
#define SS_DISCARD() { fragColor = vec4(0.0); return; }

void ssSetup(out vec2 uv, out vec4 color, out float rate, out vec2 px) {
  // Fragment position in the same space as the quad's vertex positions.
  vec2 d = FlutterFragCoord().xy - uOrigin;
  // Quad-local coordinates in [0,1]^2. The clamp is a guard for edge fragments;
  // interior fragments already resolve inside the unit square.
  float s = clamp(uInv.x * d.x + uInv.y * d.y, 0.0, 1.0);
  float t = clamp(uInv.z * d.x + uInv.w * d.y, 0.0, 1.0);

  // Bilinear over the four corners (top = LT..RT, bottom = LB..RB).
  color = mix(mix(uColLT, uColRT, s), mix(uColLB, uColRB, s), t);
  rate = mix(mix(uRate.x, uRate.y, s), mix(uRate.z, uRate.w, s), t);
  vec2 uvpx = mix(mix(uUvA.xy, uUvA.zw, s), mix(uUvB.xy, uUvB.zw, s), t);
  uv = uvpx / uTexSize;
  px = 1.0 / uTexSize;
}

// Sample + un-premultiply: the SS shader maths expects straight-alpha colour,
// but the engine's textures are premultiplied. Transparent texels (rgb already
// 0) stay 0 thanks to the max() guard.
vec4 ssTex(vec2 uv) {
  vec4 c = texture(uTex, uv);
  return vec4(c.rgb / max(c.a, 0.0001), c.a);
}

// PartColor composite over the shader-computed `Pixel`, then
// re-premultiply — the exact tail `shaders/partcolor.frag` applies, with the
// sampled texel replaced by `Pixel`. Reused rather than re-derived so the two
// paths cannot drift.
//
// `color.a` already carries the part's hierarchical alpha (pre-folded by the
// Brain), so `PartState.alpha` is NOT re-multiplied here.
vec4 ssBlend(vec4 Pixel, vec4 color, float rate) {
  // varg = (1 + fSrc*rate, fDst*rate, fDstSrc): one branch-free formula for
  // Mix / Mul / Add / Sub. rate == 0 collapses this to `Pixel` (passthrough).
  float vx = 1.0 + uCoef.x * rate;
  float vy = uCoef.y * rate;
  float vz = uCoef.z;
  vec3 rgb = Pixel.rgb * vx + mix(vec3(1.0), Pixel.rgb, vz) * color.rgb * vy;
  rgb = clamp(rgb, 0.0, 1.0);
  float a = Pixel.a * color.a;
  // Flutter expects a premultiplied fragment output.
  return vec4(rgb * a, a);
}
