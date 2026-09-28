shader_type canvas_item;

global uniform bool menu_blur = true;
global uniform float blur_strength : hint_range(0.0, 5) = 3.0;
global uniform vec4 ui_color : source_color;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

void fragment() {
	float use_original_color = step(rgb2hsv(COLOR.xyz).z, 0.3);
	if (menu_blur) {
		float radius = blur_strength * 2.5 * smoothstep(0.0, 1.0, COLOR.a);
		vec2 ps = SCREEN_PIXEL_SIZE * radius;
		// 16-tap golden-angle Fermat spiral disc blur:
		// Evenly disperses samples across the disc area, completely eliminating
		// discrete ghosting, axis spikes, and multi-image splitting.
		vec4 sum = texture(SCREEN_TEXTURE, SCREEN_UV) * 0.15;
		float total_weight = 0.15;
		const float GOLDEN_ANGLE = 2.39996323;
		for (int i = 1; i <= 15; i++) {
			float fi = float(i);
			float r = sqrt(fi / 15.0);
			float theta = fi * GOLDEN_ANGLE;
			vec2 offset = vec2(cos(theta), sin(theta)) * (r * ps);
			float weight = 1.0 - r * 0.45;
			sum += texture(SCREEN_TEXTURE, SCREEN_UV + offset) * weight;
			total_weight += weight;
		}
		vec4 blurred = (sum / total_weight) * mix(vec4(1.0), ui_color, COLOR.a);

		COLOR.rgb = mix(COLOR.rgb, blurred.rgb, use_original_color);
		COLOR.a = mix(COLOR.a, 1.0, use_original_color);
	} else {
		if (use_original_color != 0.0) {
			COLOR.rgb = ui_color.rgb;
			COLOR.a *= ui_color.a;
		}
	}
}
