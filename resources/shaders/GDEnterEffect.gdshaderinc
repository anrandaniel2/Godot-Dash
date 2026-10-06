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

float gd_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	screen_position = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(vec2(0.0), 0.0, 1.0)).xy;
	screen_uv = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy * 0.5 + 0.5;
	gd_fade = 1.0;
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
		if (scale != 1.0 || offset_gd != vec2(0.0)) {
			vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy - world_center;
			world = world * scale + world_center + vec2(offset_gd.x, -offset_gd.y) * GD_UNIT_PX;
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
		COLOR.a *= gd_fade;
	} else if (fade_power != 0.0 && enabled) {
		float fade_gradient = (1.0 - abs(screen_position.x)) * (1.0 / (transition_width * 0.02));
		fade_gradient = 1.0 - pow(1.0 - clamp(fade_gradient, 0.0, 1.0), 2.0);
		COLOR.a = mix(COLOR.a, COLOR.a * fade_gradient, fade_power);
	}
}
