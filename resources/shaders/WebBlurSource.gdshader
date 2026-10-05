shader_type canvas_item;

// Softens a texture that is already a small copy of the view. A handful of
// taps here is cheap because the viewport is a few hundred pixels across, not
// the browser window. Do not add hint_screen_texture.

void fragment() {
	// 3x3 Gaussian on the already-small copy. Five axis taps left a
	// cross-shaped smear once WebGPU stretched the result to the window.
	vec2 px = TEXTURE_PIXEL_SIZE * 1.25;
	vec4 c = texture(TEXTURE, UV) * 0.25;
	c += texture(TEXTURE, UV + vec2(px.x, 0.0)) * 0.12;
	c += texture(TEXTURE, UV - vec2(px.x, 0.0)) * 0.12;
	c += texture(TEXTURE, UV + vec2(0.0, px.y)) * 0.12;
	c += texture(TEXTURE, UV - vec2(0.0, px.y)) * 0.12;
	c += texture(TEXTURE, UV + px) * 0.07;
	c += texture(TEXTURE, UV - px) * 0.07;
	c += texture(TEXTURE, UV + vec2(px.x, -px.y)) * 0.07;
	c += texture(TEXTURE, UV + vec2(-px.x, px.y)) * 0.07;
	COLOR = c;
}
