#version 460 core

// The 13 built-in SpriteStudio integration shaders (`ss-*`) for the flutter_gpu
// backend — the GPU twin of `shaders/ss_*.frag` (Canvas) and a near-verbatim
// port of the Godot flagship's `ss_*.fs` / the Web renderer's `SSShaderLib.ts`.
//
// Real GLSL here, so the effects read the way the siblings wrote them: `discard`
// works, varyings carry the PartColor corner, and the parameters arrive in a
// struct UBO (a *struct* UBO is fine — only a dynamically-indexed uniform ARRAY
// is the Impeller/Metal miscompile trap).
//
// **One pipeline, one branch** rather than 13 pipelines: a shader part is
// already drawn on its own quad (its parameters are per-part uniforms), the
// branch is on a uniform so control flow stays uniform across the draw, and the
// alternative would mean 13 shader-bundle entries and 13 pipeline objects for a
// part kind that appears a handful of times per animation at most. Unlike the
// Canvas side there is no silent-fallback hazard to hedge against — a bad shader
// here fails the bundle build loudly.

uniform sampler2D u_texture; // sprite atlas (bilinear)

uniform ShaderInfo {
  vec4 params;    // the SHDR attribute's param0..param3
  vec4 cell_rect; // cell UV rect (minU, minV, maxU, maxV), normalised
  vec4 misc;      // (effect id, 1/texW, 1/texH, -)
} ss;

in vec2 v_uv;
in vec4 v_color; // interpolated straight corner colour
in vec4 v_coef;  // (coef.xyz, rate)

out vec4 frag_color;

// The siblings' spellings, so the bodies port verbatim.
#define ss_param0 ss.params.x
#define ss_param1 ss.params.y
#define ss_param2 ss.params.z
#define ss_cell_rect ss.cell_rect
#define TEXTURE_PIXEL_SIZE ss.misc.yz
#define vUV v_uv

const float PI = 3.141592653589793;

// Effect ids — MUST match the declaration order of `SsShaderId`
// (lib/src/render/part_shader.dart), which is what the Dart side uploads.
const int SS_SEPIA = 0;
const int SS_HSB = 1;
const int SS_STEP = 2;
const int SS_PIX = 3;
const int SS_NOISE = 4;
const int SS_BMASK = 5;
const int SS_OUTLINE = 6;
const int SS_BLUR = 7;
const int SS_WAVE = 8;
const int SS_MOVE = 9;
const int SS_SCATTER = 10;
const int SS_CIRCLE = 11;
const int SS_SPOT = 12;

// Sample + un-premultiply: the SS shader maths expects straight-alpha colour,
// but the uploaded atlas is premultiplied (see FlutterGpuBackend._upload).
vec4 ssTex(vec2 uv) {
  vec4 c = texture(u_texture, uv);
  return vec4(c.rgb / max(c.a, 0.0001), c.a);
}

// PartColor composite over the shader-computed `Pixel`, then
// re-premultiply. Identical maths to `shaders/gpu/partcolor.frag` and to the
// Canvas `ssBlend`; `v_color.a` already carries the part's hierarchical alpha
// (pre-folded by the Brain), so `PartState.alpha` is not re-multiplied.
vec4 ssFinish(vec4 Pixel) {
  float rate = v_coef.w;
  float vx = 1.0 + v_coef.x * rate;
  float vy = v_coef.y * rate;
  float vz = v_coef.z;
  vec3 rgb = Pixel.rgb * vx + mix(vec3(1.0), Pixel.rgb, vz) * v_color.rgb * vy;
  rgb = clamp(rgb, 0.0, 1.0);
  float a = Pixel.a * v_color.a;
  return vec4(rgb * a, a); // premultiplied output
}

// --- the effects ------------------------------------------------------------

vec4 ssSepia() {
  float fPower = ss_param0;
  vec4 Pixel = ssTex(vUV);
  float gray = dot(Pixel.rgb, vec3(0.298912, 0.586611, 0.114478));
  vec3 GrayRgb = vec3(gray);
  vec3 SepiaRgb = GrayRgb * vec3(1.07, 0.74, 0.43);
  vec3 toned = mix(SepiaRgb, GrayRgb, step(fPower, 0.0));
  vec3 mixed_rgb = mix(Pixel.rgb, toned, abs(fPower));
  return vec4(mixed_rgb, Pixel.a);
}

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

vec4 ssHsb() {
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
  return vec4(shifted.rgb, shifted.a);
}

vec4 ssStep() {
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
  return vec4(v, Pixel.a);
}

vec4 ssPix() {
  float fPower = ss_param0;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float v = 1.0 + 96.0 * fPower;
  vec2 step_uv = vec2(v * px.x, v * px.y);
  vec2 Coord = floor(vUV / step_uv) * step_uv;
  return ssTex(Coord);
}

float ss_noise_rand(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 ssNoise() {
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
  return Pixel;
}

vec4 ssBmask() {
  float fBrightness = ss_param0;
  vec4 Pixel = ssTex(vUV);
  float b = abs(step(fBrightness, 0.0) - max(Pixel.r, max(Pixel.g, Pixel.b)));
  if (b <= abs(fBrightness)) discard;
  return Pixel;
}

vec4 ssOutline() {
  float fThreshold = ss_param0;
  float fRatio = abs(fThreshold);
  float e = 1.0e-5;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float lo = 0.0;
  lo += step(ssTex(vUV + vec2(-px.x, 0.0)).a, fRatio);
  lo += step(ssTex(vUV + vec2(px.x, 0.0)).a, fRatio);
  lo += step(ssTex(vUV + vec2(0.0, -px.y)).a, fRatio);
  lo += step(ssTex(vUV + vec2(0.0, px.y)).a, fRatio);
  vec4 center = ssTex(vUV);
  float hi = step(fRatio + e, center.a);
  float v = min(hi * lo, 1.0);
  if (v <= 0.0) discard;
  return vec4(vec3(v), v);
}

// The ONE effect that skips the PartColor composite: it multiplies by the part
// colour instead, mirroring the SS6 reference (and both siblings). Returns the
// finished premultiplied fragment, not a `Pixel`.
vec4 ssBlurOut() {
  float fFocus = ss_param0;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 d = vec2(fFocus * px.x * 16.0, fFocus * px.y * 16.0);
  vec2 tc = vUV;
  vec4 sum = ssTex(tc);
  sum += ssTex(vec2(tc.x + d.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x + d.x, tc.y));
  sum += ssTex(vec2(tc.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y - d.y));
  sum += ssTex(vec2(tc.x + d.x, tc.y - d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y + d.y));
  sum += ssTex(vec2(tc.x - d.x, tc.y));
  sum += ssTex(vec2(tc.x, tc.y - d.y));
  vec4 Pixel = sum / 9.0;
  vec4 c = Pixel * v_color;
  return vec4(c.rgb * c.a, c.a);
}

vec4 ssWave() {
  float fWidth = ss_param0;
  float fHeight = ss_param1;
  float fPhase = ss_param2;
  vec2 Coord = vUV;
  vec2 px = TEXTURE_PIXEL_SIZE;
  float l = 384.0 * fHeight * 0.5;
  float s = l * sin(Coord.y * 384.0 * fWidth * 0.5 + PI * 2.0 * fPhase) * px.x;
  return ssTex(vec2(Coord.x + s, Coord.y));
}

vec4 ssMove() {
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
  // Constant loop bound + break: the portable form (the Canvas/impellerc and
  // WebGL1 paths reject a dynamic bound), kept here too so the two agree.
  for (int i = 1; i < 128; i++) {
    if (i >= iCount) break;
    Coord -= Vel;
    Pixel = mix(ssTex(Coord), Pixel, 0.96 * abs(fPower));
  }
  return Pixel;
}

float ss_scatter_rand(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 ssScatter() {
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
  return ssTex(Coord + v);
}

vec4 ssCircle() {
  float fPhase = ss_param0;
  float fDirection = ss_param1;
  float e = 1.0e-10;
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 uv1 = vec2(px.x + e, px.y + e);
  vec2 lt_uv = ss_cell_rect.xy;
  vec2 rb_uv = ss_cell_rect.zw;
  vec2 center_uv = (lt_uv + rb_uv) * 0.5;
  vec2 tx = vUV / uv1;
  vec2 c = center_uv / uv1;
  vec2 lt = lt_uv / uv1;
  vec2 rb = rb_uv / uv1;
  vec2 dd = rb - lt;
  vec2 v = tx - c;
  float r = min(abs(rb.x - c.x), abs(rb.y - c.y)) + e;
  float dis = length(v);
  if (dis > r) discard;
  vec2 nv = (dis > e) ? (v / dis) : vec2(1.0, 0.0);
  float uu = 1.0 - dis / r;
  float vv = (atan(nv.y, nv.x) / PI + 1.0) * 0.5 + fPhase;
  if (vv < 0.0) vv += 1.0;
  if (vv > 1.0) vv -= 1.0;
  if (fDirection <= 0.0) vv = 1.0 - vv;
  vec2 st = dd * vec2(uu, vv) * uv1;
  return ssTex(lt_uv + st);
}

vec4 ssSpot() {
  float fPower = ss_param0;
  float fDecay = ss_param1;
  float fColor = ss_param2;
  float e = 1.0e-10;
  float p = abs(fPower);
  float d_abs = abs(fDecay);
  vec2 px = TEXTURE_PIXEL_SIZE;
  vec2 uv1 = vec2(px.x + e, px.y + e);
  vec2 lt_uv = ss_cell_rect.xy;
  vec2 rb_uv = ss_cell_rect.zw;
  vec2 center_uv = (lt_uv + rb_uv) * 0.5;
  vec2 c = center_uv / uv1;
  vec2 rb = rb_uv / uv1;
  float l = min(abs(rb.x - c.x), abs(rb.y - c.y)) + e;
  vec2 t = vUV / uv1;
  vec2 v = c - t;
  float fR = max(p / (length(v / l) + e) - p, 0.0);
  float fL = max(p - length(v / l), 0.0);
  fR = clamp(mix(fR, fL, d_abs), 0.0, 1.0);
  vec3 sampled = ssTex(vUV).rgb;
  return vec4(mix(vec3(1.0), sampled, fColor), fR);
}

void main() {
  int id = int(ss.misc.x + 0.5);

  // ss-blur owns its whole output, PartColor tail included.
  if (id == SS_BLUR) {
    frag_color = ssBlurOut();
    return;
  }

  vec4 Pixel;
  if (id == SS_SEPIA) {
    Pixel = ssSepia();
  } else if (id == SS_HSB) {
    Pixel = ssHsb();
  } else if (id == SS_STEP) {
    Pixel = ssStep();
  } else if (id == SS_PIX) {
    Pixel = ssPix();
  } else if (id == SS_NOISE) {
    Pixel = ssNoise();
  } else if (id == SS_BMASK) {
    Pixel = ssBmask();
  } else if (id == SS_OUTLINE) {
    Pixel = ssOutline();
  } else if (id == SS_WAVE) {
    Pixel = ssWave();
  } else if (id == SS_MOVE) {
    Pixel = ssMove();
  } else if (id == SS_SCATTER) {
    Pixel = ssScatter();
  } else if (id == SS_CIRCLE) {
    Pixel = ssCircle();
  } else if (id == SS_SPOT) {
    Pixel = ssSpot();
  } else {
    // Unreachable — the Dart side only dispatches here for a resolved built-in.
    // Degrade to the plain PartColor path rather than to a black quad.
    Pixel = ssTex(vUV);
  }
  frag_color = ssFinish(Pixel);
}
