#version 460 core

// Flutter GPU mask coverage writer — the GPU sibling of
// shaders/mask_write.frag. One writer = one bit, pre-encoded on the CPU into the
// R/G/B channel that owns it (8 bits x 3 = 24 writers; alpha is the accumulator).
// The pass draws with additive blend, so the disjoint per-writer bits OR together
// losslessly.

uniform sampler2D u_texture; // Sprite writer's cell (a dummy for a Shape/Mesh writer)

uniform MaskBit {
  vec4 bit; // rgb = this writer's bit colour; a = cutout threshold (<0 = none)
} mask_bit;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  // Cutout: only texels above the threshold contribute coverage. A negative
  // threshold means "no cutout" (a Shape/Mesh writer: the geometry is the mask).
  if (mask_bit.bit.a >= 0.0 && texture(u_texture, v_uv).a <= mask_bit.bit.a) {
    frag_color = vec4(0.0); // additive blend: a zero fragment adds nothing
    return;
  }
  // Additive blend is premultiplied, so the bit must be written with alpha 1.
  frag_color = vec4(mask_bit.bit.rgb, 1.0);
}
