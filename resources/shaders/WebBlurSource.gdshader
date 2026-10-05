shader_type canvas_item;

// One axis of a separable Gaussian. The source is already a half-resolution
// copy, so nine taps here is cheap. Do not add hint_screen_texture.
uniform vec2 blur_dir = vec2(1.0, 0.0);
uniform float blur_px = 2.5;

void fragment() {
	vec2 step_uv = TEXTURE_PIXEL_SIZE * blur_dir * blur_px;
	vec4 c = texture(TEXTURE, UV) * 0.227027;
	c += texture(TEXTURE, UV + step_uv) * 0.1945946;
	c += texture(TEXTURE, UV - step_uv) * 0.1945946;
	c += texture(TEXTURE, UV + step_uv * 2.0) * 0.1216216;
	c += texture(TEXTURE, UV - step_uv * 2.0) * 0.1216216;
	c += texture(TEXTURE, UV + step_uv * 3.0) * 0.054054;
	c += texture(TEXTURE, UV - step_uv * 3.0) * 0.054054;
	c += texture(TEXTURE, UV + step_uv * 4.0) * 0.016216;
	c += texture(TEXTURE, UV - step_uv * 4.0) * 0.016216;
	COLOR = c;
}
