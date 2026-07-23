#version 460 core

// Flutter GPU group-tint vertex shader (§8/§10): composites an instance child's
// offscreen subtree back into the parent's target through a colour matrix.
//
// The subtree is rendered into a texture the same size as the parent target, so
// the composite is a full-target quad in NDC — no projection, no transform. The
// four corners are handed in directly as `[pos.xy, uv.xy]`.
in vec2 a_position; // NDC corner (-1..1)
in vec2 a_uv;       // 0..1 texture coord of that corner

out vec2 v_uv;

void main() {
  gl_Position = vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
}
