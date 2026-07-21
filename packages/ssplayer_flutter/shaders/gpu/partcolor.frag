#version 460 core

// Flutter GPU PartColor (§10) blend + mask replay (§3-2) — a faithful port of
// shaders/partcolor.frag to the Flutter GPU dialect, drawing a whole RUN of
// peeled parts in one batched call (the fan-out collapse). Each part's 9 vec4s
// live at pc.data[part*9 .. part*9+8]; the maths is otherwise identical to the
// Canvas reference (true bilinear, honest integer bit ops), so it pixel-matches.
//
// A flat vec4[] (not a struct[]) is used because the shader-bundle reflection
// rejects nested struct / integer-varying types.

uniform sampler2D u_texture;  // sprite atlas (bilinear)
uniform sampler2D u_coverage; // mask coverage bits (nearest; 1x1 dummy when unmasked)

// Per-part data, 9 vec4 each: col_lt, col_rt, col_lb, col_rb, rate, coef,
// mask_bits, mask_uv, mask_off. Capped at 40 parts (kMaxPartColorRun splits
// longer runs) — 40*9*16 = 5760 bytes, under impellerc's 6208-byte UBO limit.
uniform PartColorInfo {
  vec4 data[360]; // 40 * 9
} pc;

in vec2 v_local;
in vec2 v_uv;
in vec2 v_st;
flat in float v_part;

out vec4 frag_color;

bool maskPasses(vec4 mask_bits, vec4 mask_uv, vec4 mask_off) {
  if (mask_bits.w < 0.5) return true; // not masked this frame

  vec2 muv = vec2(mask_uv.x * v_local.x + mask_uv.y * v_local.y,
                  mask_uv.z * v_local.x + mask_uv.w * v_local.y) +
      mask_off.xy;
  bool visibleInside = mask_bits.z > 0.5;

  if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0) {
    return !visibleInside;
  }

  vec4 cov = texture(u_coverage, muv);
  int bits = int(floor(cov.r * 255.0 + 0.5)) |
      (int(floor(cov.g * 255.0 + 0.5)) << 8) |
      (int(floor(cov.b * 255.0 + 0.5)) << 16);
  int inc = int(mask_bits.x);
  int inv = int(mask_bits.y);

  int stencil = 0;
  for (int i = 0; i < 24; i++) {
    int bit = 1 << i;
    if ((bits & bit) != 0) {
      if ((inv & bit) != 0) {
        stencil = 255 - stencil; // §2-3 invert
      } else if ((inc & bit) != 0) {
        stencil = (stencil + 1) & 255; // §2-3 increment
      }
    }
  }
  return (stencil > 0) == visibleInside;
}

void main() {
  int base = int(v_part + 0.5) * 9;
  vec4 col_lt = pc.data[base];
  vec4 col_rt = pc.data[base + 1];
  vec4 col_lb = pc.data[base + 2];
  vec4 col_rb = pc.data[base + 3];
  vec4 rate = pc.data[base + 4];
  vec4 coef = pc.data[base + 5];

  if (!maskPasses(pc.data[base + 6], pc.data[base + 7], pc.data[base + 8])) {
    frag_color = vec4(0.0);
    return;
  }

  float s = clamp(v_st.x, 0.0, 1.0);
  float t = clamp(v_st.y, 0.0, 1.0);

  vec4 col = mix(mix(col_lt, col_rt, s), mix(col_lb, col_rb, s), t);
  float rateV = mix(mix(rate.x, rate.y, s), mix(rate.z, rate.w, s), t);

  vec4 tex = texture(u_texture, v_uv);
  vec3 pixel = tex.a > 0.0 ? tex.rgb / tex.a : tex.rgb;

  float vx = 1.0 + coef.x * rateV;
  float vy = coef.y * rateV;
  float vz = coef.z;
  vec3 rgb = pixel * vx + mix(vec3(1.0), pixel, vz) * col.rgb * vy;
  rgb = clamp(rgb, 0.0, 1.0);

  float a = tex.a * col.a;
  frag_color = vec4(rgb * a, a); // premultiplied output
}
