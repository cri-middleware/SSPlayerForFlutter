#version 460 core

// Flutter GPU PartColor blend + mask replay — the per-vertex
// attribute design. Everything comes from interpolated varyings: the
// corner colour + rate are pre-interpolated by the rasteriser (v_color /
// v_coef.w), so this shader only applies the formula and the mask gate.
// The blend maths matches shaders/partcolor.frag (the Canvas reference); the
// 4-corner gradient is the rasteriser's per-triangle interpolation (as the
// Godot / Web siblings do), not a per-fragment bilinear reconstruction.

uniform sampler2D u_texture;  // sprite atlas (bilinear)
uniform sampler2D u_coverage; // mask coverage bits (nearest; 1x1 dummy when unmasked)

in vec2 v_local;
in vec2 v_uv;
in vec4 v_color;
in vec4 v_coef;
flat in vec4 v_mask_bits;
flat in vec4 v_mask_uv;
flat in vec4 v_mask_off;

out vec4 frag_color;

bool maskPasses() {
  if (v_mask_bits.w < 0.5) return true; // not masked this frame

  vec2 muv = vec2(v_mask_uv.x * v_local.x + v_mask_uv.y * v_local.y,
                  v_mask_uv.z * v_local.x + v_mask_uv.w * v_local.y) +
      v_mask_off.xy;
  bool visibleInside = v_mask_bits.z > 0.5;

  if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0) {
    return !visibleInside;
  }

  vec4 cov = texture(u_coverage, muv);
  int bits = int(floor(cov.r * 255.0 + 0.5)) |
      (int(floor(cov.g * 255.0 + 0.5)) << 8) |
      (int(floor(cov.b * 255.0 + 0.5)) << 16);
  int inc = int(v_mask_bits.x);
  int inv = int(v_mask_bits.y);

  // `Invert` and `IncrementWrap` do not commute, so one shared
  // accumulator would make coverage depend on the order the writers are walked
  // in. Keep a plane each — the shader has no bit budget to divide, so unlike a
  // real stencil the counter takes no overlap ceiling. See shaders/partcolor.frag.
  int parity = 0; // invert writers: covered where an ODD number overlap
  int count = 0;  // increment writers: covered where ANY overlap
  for (int i = 0; i < 24; i++) {
    int bit = 1 << i;
    if ((bits & bit) != 0) {
      if ((inv & bit) != 0) {
        parity ^= 1; // invert (parity plane)
      } else if ((inc & bit) != 0) {
        count += 1; // increment (counter plane)
      }
    }
  }
  // The union of the two planes.
  bool masked = (parity != 0) || (count != 0);
  return masked == visibleInside;
}

void main() {
  if (!maskPasses()) {
    frag_color = vec4(0.0);
    return;
  }

  vec4 tex = texture(u_texture, v_uv);
  vec3 pixel = tex.a > 0.0 ? tex.rgb / tex.a : tex.rgb;

  // Formula (identical to shaders/partcolor.frag). coef = (fSrc, fDst,
  // mulFlag, 0) from render/blend.dart#partColorCoef; rate rides in v_coef.w.
  float rate = v_coef.w;
  float vx = 1.0 + v_coef.x * rate;
  float vy = v_coef.y * rate;
  float vz = v_coef.z;
  vec3 rgb = pixel * vx + mix(vec3(1.0), pixel, vz) * v_color.rgb * vy;
  rgb = clamp(rgb, 0.0, 1.0);

  float a = tex.a * v_color.a;
  frag_color = vec4(rgb * a, a); // premultiplied output
}
