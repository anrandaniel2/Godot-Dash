shader_type canvas_item;

global uniform bool menu_blur = true;
global uniform vec4 ui_color : source_color;

// The desktop blur reads SCREEN_TEXTURE. On web that copies the whole
// framebuffer and then samples it again for every panel pixel, including the
// title screen, so the menu hitches before a level is loaded. This shader
// keeps the panel's own color and never asks for that copy.

void fragment() {
	if (!menu_blur) {
		COLOR.rgb = ui_color.rgb;
		COLOR.a *= ui_color.a;
	}
}
