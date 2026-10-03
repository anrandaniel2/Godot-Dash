shader_type canvas_item;
#include "Color.gdshaderinc"

instance uniform float hue = 0.33333;
instance uniform float enabled_factor: hint_range(0.0, 1.0, 0.1) = 1.0;
instance uniform float flash_factor: hint_range(0.0, 1.0, 0.1) = 0.0;

void fragment() {
	vec3 hsv = rgb_to_hsv(COLOR.rgb);
	float is_outline = smoothstep(1.0, 0.0, hsv.y);
	hsv.x = hue;
	hsv.y *= enabled_factor;
	hsv.y = mix(hsv.y, 0.0, flash_factor);
	hsv.z = mix(
		mix(hsv.z * 0.1, hsv.z * 0.2, is_outline),
		hsv.z,
		enabled_factor
	);
	COLOR.rgb = hsv_to_rgb(hsv);
	//COLOR.rgb = vec3(is_outline);
}
