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
flat in vec4 v_mask_bits; // (visibleInside, enabled, tilesX, tilesY)
flat in vec4 v_mask_uv;
flat in vec4 v_mask_off;
flat in vec4 v_mask_inc;  // increment sets of coverage tiles 0..3
flat in vec4 v_mask_inv;  // invert sets of coverage tiles 0..3

out vec4 frag_color;

// One coverage tile's 24 bits at `muv`. Past 24 writers the texture is split
// into tiles (2 side by side, then 2x2), each holding the whole writer box at a
// lower resolution; the nudge keeps a uv of exactly 1 inside its own tile.
int tileBits(vec2 muv, int tile, vec2 tiles) {
  vec2 cell = vec2(float(tile % int(tiles.x)), float(tile / int(tiles.x)));
  vec4 cov = texture(u_coverage, (clamp(muv, 0.0, 0.9999) + cell) / tiles);
  return int(floor(cov.r * 255.0 + 0.5)) |
      (int(floor(cov.g * 255.0 + 0.5)) << 8) |
      (int(floor(cov.b * 255.0 + 0.5)) << 16);
}

// `Invert` and `IncrementWrap` do not commute, so one shared accumulator would
// make coverage depend on the order the writers are walked in. Keep a plane
// each — the shader has no bit budget to divide, so unlike a real stencil the
// counter takes no overlap ceiling. See shaders/partcolor.frag.
//
// Returns (parity, count): parity 1 where an ODD number of invert writers
// overlap, count > 0 where ANY increment writer does.
ivec2 replayTile(int bits, int inc, int inv) {
  int parity = 0;
  int count = 0;
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
  return ivec2(parity, count);
}

// mask_bits = (visibleInside, enabled, tilesX, tilesY); inc / inv = the
// scope-resolved writer sets of tiles 0..3.
bool maskReplay(vec2 local, vec4 mask_bits, vec4 mask_uv, vec2 mask_off,
                vec4 inc, vec4 inv) {
  if (mask_bits.y < 0.5) return true; // not masked this frame

  vec2 muv = vec2(mask_uv.x * local.x + mask_uv.y * local.y,
                  mask_uv.z * local.x + mask_uv.w * local.y) + mask_off;
  bool visibleInside = mask_bits.x > 0.5;

  if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0) {
    return !visibleInside;
  }

  vec2 tiles = max(mask_bits.zw, vec2(1.0));
  int tileCount = int(tiles.x * tiles.y + 0.5);
  // Unrolled: no dynamically indexed vector, the construct Impeller/Metal
  // miscompiles.
  ivec2 acc = replayTile(tileBits(muv, 0, tiles), int(inc.x), int(inv.x));
  if (tileCount > 1) {
    ivec2 a = replayTile(tileBits(muv, 1, tiles), int(inc.y), int(inv.y));
    acc = ivec2(acc.x ^ a.x, acc.y + a.y);
  }
  if (tileCount > 2) {
    ivec2 a = replayTile(tileBits(muv, 2, tiles), int(inc.z), int(inv.z));
    acc = ivec2(acc.x ^ a.x, acc.y + a.y);
  }
  if (tileCount > 3) {
    ivec2 a = replayTile(tileBits(muv, 3, tiles), int(inc.w), int(inv.w));
    acc = ivec2(acc.x ^ a.x, acc.y + a.y);
  }
  // The union of the two planes.
  bool masked = (acc.x != 0) || (acc.y != 0);
  return masked == visibleInside;
}

// The replay above is shaders/gpu/shapemask.frag's too — keep the two in step.
bool maskPasses() {
  return maskReplay(v_local, v_mask_bits, v_mask_uv, v_mask_off.xy, v_mask_inc,
                    v_mask_inv);
}

void main() {
  // Discarded, not transparent: Invert's ZERO destination factor would black
  // out the destination under a transparent fragment, where a hidden one must
  // leave it alone.
  if (!maskPasses()) {
    discard;
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
