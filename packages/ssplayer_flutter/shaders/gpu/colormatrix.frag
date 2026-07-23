#version 460 core

// Flutter GPU group-tint fragment shader (§8/§10) — the Instance-part PartColor
// applied to a whole child sub-animation, and the GPU twin of the Canvas
// backend's `saveLayer(ColorFilter.matrix)`.
//
// It must match `ui.ColorFilter.matrix` exactly, so it follows the same three
// steps Skia/Impeller take: **unpremultiply**, apply `m·rgb + offset`, clamp,
// **re-premultiply**. Applying the matrix to premultiplied rgb instead would
// scale the offset by alpha and diverge on every semi-transparent pixel.
//
// Only the rgb rows are carried: the alpha row of a whole-part tint is always
// the identity (§10 — α travels with the geometry, folded per-part down the
// instance chain by DrawFrame.alphaScale, never in the tint).

uniform sampler2D u_texture; // the subtree's offscreen target

uniform TintInfo {
  vec4 row_r; // rgb = the r row's rgb coefficients, w = the r offset (0..1)
  vec4 row_g;
  vec4 row_b;
} tint;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  vec4 src = texture(u_texture, v_uv);
  if (src.a <= 0.0) {
    frag_color = vec4(0.0);
    return;
  }
  vec3 rgb = src.rgb / src.a; // unpremultiply
  vec3 tinted = vec3(dot(tint.row_r.rgb, rgb) + tint.row_r.w,
                     dot(tint.row_g.rgb, rgb) + tint.row_g.w,
                     dot(tint.row_b.rgb, rgb) + tint.row_b.w);
  tinted = clamp(tinted, 0.0, 1.0);
  frag_color = vec4(tinted * src.a, src.a); // premultiplied output
}
