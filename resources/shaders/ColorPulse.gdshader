shader_type canvas_item;
#include "Color.gdshaderinc"

instance uniform vec4 pulse_color: source_color = vec4(1.0, 1.0, 1.0, 1.0);
instance uniform float factor: hint_range(0.0, 1.0, 0.01) = 0.0;

void fragment()
{
	COLOR.rgb = mix(COLOR.rgb, pulse_color.rgb, factor * rgb_to_hsv(vec3(COLOR.rgb)).z * 1.5);
}