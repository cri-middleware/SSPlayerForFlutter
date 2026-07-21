#version 460 core

// Flutter GPU textured-sprite fragment shader (Normal / Mesh / Effect kinds).
//
// Both the sampled texel (the GPU texture registry uploads rawRgba, which is
// premultiplied) and v_color (premultiplied) match the Canvas reference, which
// draws these kinds with BlendMode.modulate (component-wise texel * vertex
// colour). The framebuffer composite (srcOver / add / multiply / ...) is set on
// the RenderPass via setColorBlendEquation, not here.
//
// Exact premultiplied-alpha parity vs the Canvas path is validated visually in
// Phase 1 against examples/overall (backend toggle on the same frame).

uniform sampler2D u_texture;

in vec2 v_uv;
in vec4 v_color;

out vec4 frag_color;

void main() {
  frag_color = texture(u_texture, v_uv) * v_color;
}
