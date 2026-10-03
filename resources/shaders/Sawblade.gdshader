shader_type canvas_item;

uniform float gradient_start: hint_range(0.0, 1.0, 0.01);
uniform float gradient_end: hint_range(0.0, 1.0, 0.01);

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	COLOR.a *= smoothstep(
		gradient_start,
		gradient_end,
		length(uv)
	);
}