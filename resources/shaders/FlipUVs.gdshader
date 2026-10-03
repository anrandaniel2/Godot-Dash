shader_type canvas_item;
uniform bvec2 flip;

void fragment() {
	vec2 uv = UV;
	if (flip.x) {
		uv.x = 1.0 - uv.x;
	}
	if (flip.y) {
		uv.y = 1.0 - uv.y;
	}
	COLOR = texture(TEXTURE, uv);
}