shader_type canvas_item;
render_mode blend_add;

// One sample of the small bloom mask, stretched over the level. This is the
// web substitute for Compatibility glow, which is several fullscreen passes.
uniform sampler2D glow_tex : filter_linear, repeat_disable;
uniform float intensity = 0.85;

void fragment() {
	vec4 bloom = texture(glow_tex, SCREEN_UV);
	COLOR = vec4(bloom.rgb * intensity, bloom.a);
}
