shader_type canvas_item;

global uniform bool menu_blur = true;
global uniform float blur_strength : hint_range(0.0, 5) = 3.0;
global uniform vec4 ui_color : source_color;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap, repeat_disable;


vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Plain blur: a 3x3 tent of taps on a downscaled mip of the screen. The mip
// does most of the widening, the taps hide its blockiness. Nine reads per
// pixel, only on panel fill.
vec3 blurred_screen(vec2 uv, vec2 pixel, float lod) {
	vec2 step_uv = pixel * exp2(lod);
	vec3 sum = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = float((2 - abs(x)) * (2 - abs(y)));
			sum += textureLod(SCREEN_TEXTURE, uv + vec2(float(x), float(y)) * step_uv, lod).rgb * w;
		}
	}
	return sum / 16.0;
}

void fragment() {
	// 1 on the panel fill: the theme's panel styleboxes are near-black (value
	// <= 0.3), and those pixels show the blurred, ui_color-tinted backdrop.
	// Brighter pixels - borders, and text/icons that inherit this material via
	// use_parent_material - keep their own colour.
	float is_fill = step(rgb2hsv(COLOR.rgb).z, 0.3);
	if (is_fill != 0.0) {
		if (menu_blur) {
			vec3 blurred = blurred_screen(SCREEN_UV, SCREEN_PIXEL_SIZE, max(blur_strength, 0.0));
			vec4 tint = mix(vec4(1.0), ui_color, COLOR.a);
			COLOR = vec4(blurred * tint.rgb, 1.0);
		} else {
			COLOR.rgb = ui_color.rgb;
			COLOR.a *= ui_color.a;
		}
	}
}
