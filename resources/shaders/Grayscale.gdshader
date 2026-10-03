shader_type canvas_item;

uniform float grayscale_factor = 0.0;
uniform bool use_lum = false;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

void fragment() {
	vec4 bg = texture(screen_texture, SCREEN_UV);
	float gray = use_lum ? dot(bg.rgb, vec3(0.2126, 0.7152, 0.0722)) : (bg.r + bg.g + bg.b) / 3.0;
	COLOR.rgb = mix(bg.rgb, vec3(gray), grayscale_factor);
	COLOR.a = bg.a;
}

