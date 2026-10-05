shader_type canvas_item;

global uniform bool menu_blur = true;
global uniform vec4 ui_color : source_color;

// One sample of a texture that was already blurred at a low resolution.
// hint_screen_texture is intentionally absent: that hint copies the full
// framebuffer, and on the web export that copy is the hitch.
uniform sampler2D blur_tex : filter_linear, repeat_disable;

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
		// ViewportTexture is Y-flipped on RenderingDevice (WebGPU/Mobile).
		// Sampling SCREEN_UV unflipped mapped the frost onto the wrong
		// part of the panel.
		vec2 uv = vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y);
		vec4 blurred = texture(blur_tex, uv) * mix(vec4(1.0), ui_color, COLOR.a);
		COLOR.rgb = mix(COLOR.rgb, blurred.rgb, use_original_color);
		COLOR.a = mix(COLOR.a, 1.0, use_original_color);
	} else if (use_original_color != 0.0) {
		COLOR.rgb = ui_color.rgb;
		COLOR.a *= ui_color.a;
	}
}
