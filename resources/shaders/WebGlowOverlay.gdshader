shader_type canvas_item;
render_mode blend_add;

// Samples this rect's own texture. Do not use SCREEN_UV or hint_screen_texture:
// those read the framebuffer, which on web is a torn previous frame and, added
// back on top, smears every bright pixel into a trail.
// HDR 2D (project viewport/hdr_2d) makes additive LDR bloom read too hot
// on WebGPU. 0.45 keeps the halo without washing the scene.
uniform float intensity = 0.45;

void fragment() {
	vec4 bloom = texture(TEXTURE, UV);
	COLOR = vec4(bloom.rgb * intensity, bloom.a);
}
