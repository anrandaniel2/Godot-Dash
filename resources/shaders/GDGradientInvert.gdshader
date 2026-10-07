// Gradient trigger 2903, Invert blending: premultiplied
// GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_COLOR, i.e. s + d - 2 * s * d
// with s = colour * alpha. Fixed-function blending cannot weight the source
// by the destination, so the destination is read from the screen texture.
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

void fragment() {
	vec3 dst = texture(screen_texture, SCREEN_UV).rgb;
	vec3 src = COLOR.rgb * COLOR.a;
	COLOR = vec4(src + dst - 2.0 * src * dst, 1.0);
}
