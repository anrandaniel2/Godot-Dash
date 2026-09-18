shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec4 base : source_color = vec4(0.952941, 0.666667, 0.364706, 1.0);
uniform float sepia_factor = 0.0;

void fragment() {
	vec3 c = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	float v = dot(c, vec3(0.33333, 0.33333, 0.33333));
	v = sqrt(v);
	vec3 sepia_col = base.rgb * v;
	COLOR.rgb = mix(c, sepia_col, sepia_factor);
}

