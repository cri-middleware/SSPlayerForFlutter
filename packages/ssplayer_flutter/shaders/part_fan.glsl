// A Normal part's corner gradient, for the Canvas shaders that rebuild it per
// fragment: `partcolor.frag` and `ss_shader_common.glsl` both `#include` this.
// Not a shader of its own.
//
// A Normal part is a fan of four triangles around its centre, whose colour and
// rate are the four corners' average, and the gradient is linear on each
// triangle. Bilinear over the corners shades the part differently wherever two
// corners disagree, and the GPU backend, which draws the fan as vertices, would
// no longer match.
//
// Returns weights on the corners (LT, RT, LB, RB) for quad-local (s, t) in
// [0,1]^2; dot them with the corner values. These shaders see the quad only
// through an affine, so the centre sits at its middle, (0.5, 0.5), and its
// weight is spread evenly over the corners it averages.
vec4 fanWeights(float s, float t) {
  vec4 w;
  float hub;
  if (t <= s && t <= 1.0 - s) {
    // Top triangle: LT, RT, centre.
    hub = 2.0 * t;
    w = vec4(1.0 - s - t, s - t, 0.0, 0.0);
  } else if (t >= s && t >= 1.0 - s) {
    // Bottom: LB, RB, centre.
    hub = 2.0 - 2.0 * t;
    w = vec4(0.0, 0.0, t - s, s + t - 1.0);
  } else if (s <= t) {
    // Left: LT, LB, centre.
    hub = 2.0 * s;
    w = vec4(1.0 - s - t, 0.0, t - s, 0.0);
  } else {
    // Right: RT, RB, centre.
    hub = 2.0 - 2.0 * s;
    w = vec4(0.0, s - t, 0.0, s + t - 1.0);
  }
  return w + vec4(0.25 * hub);
}
