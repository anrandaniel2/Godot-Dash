shader_type canvas_item;
render_mode blend_add;
uniform float bias = 0.9;

void fragment() {
	COLOR *= vec4(1.0, 1.0, 1.0, clamp(abs(UV.r - 1.0) * bias, 0.0, 1.0));
}