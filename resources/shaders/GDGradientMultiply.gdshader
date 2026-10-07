// Gradient trigger 2903, Multiply blending: premultiplied GL_DST_COLOR,
// GL_ONE_MINUS_SRC_ALPHA, i.e. dst * (1 - a + a * colour).
shader_type canvas_item;
render_mode blend_mul, unshaded;

void fragment() {
	COLOR = vec4(mix(vec3(1.0), COLOR.rgb, COLOR.a), 1.0);
}
