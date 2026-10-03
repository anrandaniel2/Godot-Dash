shader_type canvas_item;
render_mode blend_add;

// Samples this rect's own texture. Do not use SCREEN_UV or hint_screen_texture:
// those read the framebuffer, which on web is a torn previous frame and, added
// back on top, smears every bright pixel into a trail.
uniform float intensity = 0.7;

void fragment() {
	vec4 bloom = texture(TEXTURE, UV);
	COLOR = vec4(bloom.rgb * intensity, bloom.a);
}
