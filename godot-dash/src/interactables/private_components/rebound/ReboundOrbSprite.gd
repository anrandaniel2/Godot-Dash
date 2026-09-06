@tool
class_name ReboundOrbSprite
extends ReboundSprite

func _draw() -> void:
	if not visible_on_screen_notifier.is_on_screen():
		return
	var inner_radius: float = lerpf(28, 44, _factor_smoothed)
	var amplitude: float = lerpf(0.75, 1.5, _factor_smoothed)
	var color: Color = GRADIENT.sample(_factor_smoothed)
	# Exterior ring
	draw_sine_circle(60.0, amplitude)
	# Interior Fill
	update_radial_gradient(color)
	gradient_texture.gradient.set_offset(1, lerpf(0.33, 0.75, _factor_smoothed))
	draw_sine_circle(inner_radius - 2.0, amplitude, color, true)
	# Interior ring
	draw_sine_circle(inner_radius, amplitude)
	# Set particle emitter color
	particle_emitter.modulate = color


func draw_sine_circle(radius: float, amplitude: float = 1.0, color: Color = Color.WHITE, fill: bool = false, frequency: float = 6.0) -> void:
	var points: PackedVector2Array
	var uvs: PackedVector2Array
	amplitude *= radius * 0.1
	for sample: int in 91:
		var sample_angle: float = deg_to_rad(sample * 4)
		var sample_radius: float = radius + (sin(sample_angle * frequency - PI / 2) * amplitude)
		var point: Vector2 = Vector2.from_angle(sample_angle) * sample_radius
		points.append(point)
		if fill:
			uvs.append(point / 128.0 + Vector2(0.5, 0.5))
	if fill:
		draw_polygon(points, [], uvs, gradient_texture)
	else:
		draw_polyline(points, color, 6.25, Config.anti_aliasing == Viewport.MSAA_DISABLED)
