shader_type canvas_item;

// Softens a texture that is already a small copy of the view. A handful of
// taps here is cheap because the viewport is a few hundred pixels across, not
// the browser window. Do not add hint_screen_texture.

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * 1.35;
	vec4 c = texture(TEXTURE, UV) * 0.36;
	c += texture(TEXTURE, UV + vec2(px.x, 0.0)) * 0.16;
	c += texture(TEXTURE, UV - vec2(px.x, 0.0)) * 0.16;
	c += texture(TEXTURE, UV + vec2(0.0, px.y)) * 0.16;
	c += texture(TEXTURE, UV - vec2(0.0, px.y)) * 0.16;
	COLOR = c;
}
