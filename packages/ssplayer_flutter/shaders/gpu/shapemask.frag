#version 460 core

// Flutter GPU masked-Shape fragment shader: gate a Shape's per-vertex colour by
// the mask coverage (§3-2 replay), mirroring the Canvas `_drawMaskedShape` (which
// runs partcolor.frag as a no-op-colour gate over the shape's drawVertices
// gradient). The colour is already premultiplied by the Shape bake.

uniform sampler2D u_coverage; // mask coverage bits (nearest)

uniform MaskInfo {
  vec4 mask_bits; // (incrementSet, invertSet, visibleInside, enabled)
  vec4 mask_uv;   // player-local -> coverage UV basis [m00, m01, m10, m11]
  vec4 mask_off;  // xy = offset
} mask;

in vec2 v_local;
in vec4 v_color;

out vec4 frag_color;

bool maskPasses() {
  if (mask.mask_bits.w < 0.5) return true;

  vec2 muv = vec2(mask.mask_uv.x * v_local.x + mask.mask_uv.y * v_local.y,
                  mask.mask_uv.z * v_local.x + mask.mask_uv.w * v_local.y) +
      mask.mask_off.xy;
  bool visibleInside = mask.mask_bits.z > 0.5;

  if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0) {
    return !visibleInside;
  }

  vec4 cov = texture(u_coverage, muv);
  int bits = int(floor(cov.r * 255.0 + 0.5)) |
      (int(floor(cov.g * 255.0 + 0.5)) << 8) |
      (int(floor(cov.b * 255.0 + 0.5)) << 16);
  int inc = int(mask.mask_bits.x);
  int inv = int(mask.mask_bits.y);

  int stencil = 0;
  for (int i = 0; i < 24; i++) {
    int bit = 1 << i;
    if ((bits & bit) != 0) {
      if ((inv & bit) != 0) {
        stencil = 255 - stencil;
      } else if ((inc & bit) != 0) {
        stencil = (stencil + 1) & 255;
      }
    }
  }
  return (stencil > 0) == visibleInside;
}

void main() {
  if (!maskPasses()) {
    frag_color = vec4(0.0);
    return;
  }
  frag_color = v_color; // premultiplied
}
