shader_type canvas_item;

global uniform bool menu_blur = true;
global uniform float blur_strength : hint_range(0.0, 5) = 3.0;
global uniform vec4 ui_color : source_color;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;


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
		vec4 blurred = texture(SCREEN_TEXTURE, SCREEN_UV, blur_strength * smoothstep(0, 1, COLOR.a)) * mix(vec4(1), ui_color, COLOR.a);
		COLOR.rgb = mix(COLOR.rgb, blurred.rgb, use_original_color);
		COLOR.a = mix(COLOR.a, 1.0, use_original_color);
	} else {
		if (use_original_color != 0.0) {
			COLOR.rgb = ui_color.rgb;
			COLOR.a *= ui_color.a;
		}
	}
}