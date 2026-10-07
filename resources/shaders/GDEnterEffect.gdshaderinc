// Edge fade and enter effects shared by FadeEnterEffect (normal blend) and
// FadeEnterEffectAdditive. gd_enter_effect < 0 keeps the project's own
// transition (Level.transition_width / fade_power / move_power /
// scale_power); 1..13 is a Geometry Dash applyEnterEffect type, set by the
// native trigger runtime for imported levels.
//
// GD law (cgytrus/AlgebraDash update_visibility_rewrite.cpp, a drop-in
// rewrite of GD 2.2 PlayLayer::updateVisibility / applyEnterEffect):
//   fade  = clamp(distance to the nearer screen edge / 70, 0, 1)
//   enter = clamp(distance to the nearer screen edge * 0.017, 0, 1)
// in GD units, measured at the object's centre. Effects: 2 scale up
// (scale = enter), 3 scale down (1 + 0.75 * (1 - enter)), 4/5 start 100
// units below / above, 6/7 start 100 units right / left (AlgebraDash's
// signs), 8..12 angled entries of 100 units.

// GD 2.2 GJGameState m_enterChannelMap / m_exitChannelMap for channel 0, as
// applyEnterEffect types (type = -id - 1 of GJBaseGameLayer::
// updateActiveEnterEffect): objects right of the screen centre use the
// enter type, objects left of it the exit type. 13 is 1915 (no fade, no
// enter). gd_enter_effect < 0 means not a GD level.
global uniform int gd_enter_effect;
global uniform int gd_exit_effect;
// Type 14: custom Enter Move / Rotate / Scale / Fade / Tint (3017-3021),
// packed by the native runtime's enter_custom_pack (see there for layout).
global uniform mat4 gd_enter_custom_move;
global uniform mat4 gd_enter_custom_rotate;
global uniform mat4 gd_enter_custom_scale;
global uniform mat4 gd_enter_custom_fade;
global uniform mat4 gd_enter_custom_tint;
global uniform mat4 gd_exit_custom_move;
global uniform mat4 gd_exit_custom_rotate;
global uniform mat4 gd_exit_custom_scale;
global uniform mat4 gd_exit_custom_fade;
global uniform mat4 gd_exit_custom_tint;

uniform bool enabled = true;

uniform float transition_width: hint_range(0.0, 100.0, 1.0) = 15.0;
uniform float fade_power = 1.0;
uniform float move_power = 0.0;
uniform float scale_power = 0.0;

// Multi-pass shader
uniform bool use_canvas_group = false;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

const float GD_UNIT_PX = 128.0 / 30.0;

varying vec2 screen_position;
varying vec2 screen_uv;
varying float gd_fade;
varying vec4 gd_tint;

// GD easing (native gd_ease / gd_ease_in): 1-3 ease, 4-6 elastic, 7-9
// bounce, 10-12 exponential, 13-15 sine, 16-18 back; in-out, in, out.
float gd_bounce_out(float x) {
	if (x < 1.0 / 2.75) return 7.5625 * x * x;
	if (x < 2.0 / 2.75) { x -= 1.5 / 2.75; return 7.5625 * x * x + 0.75; }
	if (x < 2.5 / 2.75) { x -= 2.25 / 2.75; return 7.5625 * x * x + 0.9375; }
	x -= 2.625 / 2.75;
	return 7.5625 * x * x + 0.984375;
}
float gd_ease_in(int family, float rate, float x) {
	if (x <= 0.0) return 0.0;
	if (x >= 1.0) return 1.0;
	if (family == 0) return x <= 0.01 ? x * pow(0.01, rate - 1.0) : pow(x, rate);
	if (family == 1) return pow(2.0, 10.0 * (x - 1.0)) * sin(PI * (0.5 + (2.0 - 2.0 * x) / rate));
	if (family == 2) return 1.0 - gd_bounce_out(1.0 - x);
	if (family == 3) return pow(2.0, 10.0 * (x - 1.0));
	if (family == 4) return 1.0 - cos(0.5 * PI * x);
	return 3.5949095 * x * x * x - 2.5949095 * x * x;
}
float gd_ease(int easing, float rate, float t) {
	t = clamp(t, 0.0, 1.0);
	if (easing <= 0 || easing > 18) return t;
	if (!(rate > 0.0)) rate = 2.0;
	int family = (easing - 1) / 3;
	int mode = (easing - 1) % 3;
	if (mode == 1) return gd_ease_in(family, rate, t);
	if (mode == 2) {
		if (family == 0) return pow(t, 1.0 / rate);
		return 1.0 - gd_ease_in(family, rate, 1.0 - t);
	}
	return t < 0.5 ? gd_ease_in(family, rate, 2.0 * t) / 2.0 : 1.0 - gd_ease_in(family, rate, 2.0 - 2.0 * t) / 2.0;
}
// Area strength of one packed custom effect at edge distance d (GD units):
// 1 at the border, 0 from Length on (native area_sample / area_strength).
float gd_custom_strength(mat4 m, float d, bool leaving) {
	int flags = int(m[0].w);
	if ((flags & 1) == 0) return 0.0;
	float s = (d - m[0].y) * m[1].x;
	float length = m[0].x;
	float x = length != 0.0 ? s / length : (s > 0.0 ? 1.0 : 0.0);
	float dz = m[0].z;
	float r = dz == 0.0 ? x : (x - dz) / (1.0 - dz);
	r = clamp(r, 0.0, 1.0);
	float u = (flags & 2) != 0 ? 1.0 - r : r;
	if (u >= 1.0) return 0.0;
	bool second = (flags & 4) != 0 && leaving;
	return 1.0 - gd_ease(int(second ? m[1].w : m[1].y), second ? m[2].x : m[1].z, u);
}

float gd_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	screen_position = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(vec2(0.0), 0.0, 1.0)).xy;
	screen_uv = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy * 0.5 + 0.5;
	gd_fade = 1.0;
	gd_tint = vec4(0.0);
	if (enabled && gd_enter_effect >= 0) {
		vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
		vec2 view_center = (CANVAS_MATRIX * vec4(world_center, 0.0, 1.0)).xy;
		float px_per_unit = max(length(CANVAS_MATRIX[0].xy) * GD_UNIT_PX, 0.0001);
		float view_width = 2.0 / abs(SCREEN_MATRIX[0][0]) / px_per_unit;
		float view_height = 2.0 / abs(SCREEN_MATRIX[1][1]) / px_per_unit;
		float x = view_center.x / px_per_unit;
		bool is_right = x > view_width * 0.5;
		int effect = is_right ? gd_enter_effect : gd_exit_effect;
		float edge = is_right ? view_width - x : x;
		gd_fade = effect == 13 ? 1.0 : clamp(edge / 70.0, 0.0, 1.0);
		float enter = clamp(edge * 0.017, 0.0, 1.0);
		float scale = 1.0;
		vec2 offset_gd = vec2(0.0); // GD units, +Y up
		float hidden = 1.0 - enter;
		// Height above the screen bottom; GD splits at camera y + 90.
		bool upper = view_height - view_center.y / px_per_unit >= 90.0;
		if (effect == 2) {
			scale = enter;
		} else if (effect == 3) {
			scale = hidden * 0.75 + 1.0;
		} else if (effect == 4) {
			offset_gd.y = -hidden * 100.0;
		} else if (effect == 5) {
			offset_gd.y = hidden * 100.0;
		} else if (effect == 6) {
			offset_gd.x = hidden * 100.0;
		} else if (effect == 7) {
			offset_gd.x = -hidden * 100.0;
		} else if (effect >= 8 && effect <= 12) {
			float angle = 0.0;
			if (effect == 8) angle = upper ? 45.0 : 135.0;
			else if (effect == 9) angle = upper ? -45.0 : -135.0;
			else if (effect == 10) angle = (gd_hash(world_center) * 2.0 - 1.0) * 180.0;
			else if (effect == 11) angle = upper ? 0.0 : 180.0;
			else angle = upper ? 180.0 : 0.0;
			float a = radians(angle - 90.0);
			offset_gd = -vec2(cos(a), sin(a)) * hidden * 100.0;
		}
		vec2 scale_xy = vec2(scale);
		float spin = 0.0;
		if (effect == 14) {
			bool leaving = !is_right;
			mat4 c_move = is_right ? gd_enter_custom_move : gd_exit_custom_move;
			mat4 c_rotate = is_right ? gd_enter_custom_rotate : gd_exit_custom_rotate;
			mat4 c_scale = is_right ? gd_enter_custom_scale : gd_exit_custom_scale;
			mat4 c_fade = is_right ? gd_enter_custom_fade : gd_exit_custom_fade;
			mat4 c_tint = is_right ? gd_enter_custom_tint : gd_exit_custom_tint;
			float k = gd_custom_strength(c_move, edge, leaving);
			offset_gd += k * vec2(c_move[2].y, c_move[2].z);
			spin = gd_custom_strength(c_rotate, edge, leaving) * c_rotate[2].y;
			k = gd_custom_strength(c_scale, edge, leaving);
			scale_xy *= vec2(1.0) + k * (vec2(c_scale[2].y, c_scale[2].z) - vec2(1.0));
			k = gd_custom_strength(c_fade, edge, leaving);
			if ((int(c_fade[0].w) & 1) != 0) gd_fade *= clamp(c_fade[2].z + (c_fade[2].y - c_fade[2].z) * k, 0.0, 1.0);
			k = gd_custom_strength(c_tint, edge, leaving);
			gd_tint = vec4(c_tint[2].y, c_tint[2].z, c_tint[2].w, clamp(k * c_tint[3].x, 0.0, 1.0));
		}
		if (scale_xy != vec2(1.0) || offset_gd != vec2(0.0) || spin != 0.0) {
			vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy - world_center;
			float a = radians(spin); // GD degrees, clockwise on screen (y down)
			world = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * (world * scale_xy);
			world = world + world_center + vec2(offset_gd.x, -offset_gd.y) * GD_UNIT_PX;
			VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 0.0, 1.0)).xy;
		}
	} else if (enabled) {
		float power = (1.0 - abs(screen_position.x)) * (1.0 / (transition_width * 0.02));
		power = 1.0 - pow(1.0 - clamp(power, 0.0, 1.0), 2.0);
		vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
		VERTEX = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy - world_center;
		if (scale_power != 0.0) {
			VERTEX = mix(1, power, scale_power) > .0 ? mix(VERTEX, VERTEX * power, scale_power) : vec2(0, 0);
		}
		if (move_power != 0.0) {
			VERTEX.y -= (1.0 - power) * move_power * 1000.0;
		}
		VERTEX = (inverse(MODEL_MATRIX) * vec4(VERTEX + world_center, 0.0, 1.0)).xy;
	}
}

void fragment() {
	if (use_canvas_group) {
		vec4 screen_color = textureLod(screen_texture, screen_uv, 0.0);
		if (screen_color.a > 0.0001) {
			screen_color.rgb /= screen_color.a;
		}
		COLOR *= screen_color;
	}
	if (enabled && gd_enter_effect >= 0) {
		COLOR.rgb = mix(COLOR.rgb, gd_tint.rgb, gd_tint.a);
		COLOR.a *= gd_fade;
	} else if (fade_power != 0.0 && enabled) {
		float fade_gradient = (1.0 - abs(screen_position.x)) * (1.0 / (transition_width * 0.02));
		fade_gradient = 1.0 - pow(1.0 - clamp(fade_gradient, 0.0, 1.0), 2.0);
		COLOR.a = mix(COLOR.a, COLOR.a * fade_gradient, fade_power);
	}
}
