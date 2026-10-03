shader_type canvas_item;

// Turns a small copy of the frame into a bloom mask. Runs at that small size.
// A flat blue sky stays dark here: only pixels that are actually bright in
// luminance, or bright in more than one channel, survive.

void fragment() {
	vec3 c = clamp(texture(TEXTURE, UV).rgb, vec3(0.0), vec3(1.0));
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float gate = smoothstep(0.50, 0.86, luma);
	float channels = step(0.78, c.r) + step(0.78, c.g) + step(0.78, c.b);
	vec3 lifted = max(c - vec3(0.72), vec3(0.0)) * step(1.5, channels);
	vec3 bloom = c * gate * 0.85 + lifted * 0.7;
	float amt = clamp(max(bloom.r, max(bloom.g, bloom.b)), 0.0, 1.0);
	COLOR = vec4(bloom, amt);
}
