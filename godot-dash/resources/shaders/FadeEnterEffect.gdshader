shader_type canvas_item;

uniform bool enabled = true;

uniform float transition_width: hint_range(0.0, 100.0, 1.0) = 15.0;
uniform float fade_power = 1.0;
uniform float move_power = 0.0;
uniform float scale_power = 0.0;

// Multi-pass shader
uniform bool use_canvas_group = false;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

varying vec2 screen_position;
varying vec2 screen_uv;

void vertex() {
	screen_position = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(vec2(0.0), 0.0, 1.0)).xy;
	screen_uv = (SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy * 0.5 + 0.5;
	float power = (1.0 - abs(screen_position.x)) * (1.0 / (transition_width * 0.02));
	power = 1.0 - pow(1.0 - clamp(power, 0.0, 1.0), 2.0);
	if (enabled) {
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

	if (fade_power != 0.0 && enabled) {
		float fade_gradient = (1.0 - abs(screen_position.x)) * (1.0 / (transition_width * 0.02));
		fade_gradient = 1.0 - pow(1.0 - clamp(fade_gradient, 0.0, 1.0), 2.0);
		COLOR.a = mix(COLOR.a, COLOR.a * fade_gradient, fade_power);
	}
}
