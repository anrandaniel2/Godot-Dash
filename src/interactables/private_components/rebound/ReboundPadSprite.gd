@tool
class_name ReboundPadSprite
extends ReboundSprite

@export var _hitbox: CollisionShape2D
@export var _pad: PadInteractable
var draw_offset: Vector2


func _draw() -> void:
	if not visible_on_screen_notifier.is_on_screen():
		return
	var color: Color = GRADIENT.sample(_factor_smoothed)
	var radius: float = 64.0
	var draw_position: Vector2 = Vector2.DOWN * lerpf(52.0, 42.0, _factor_smoothed)
	var amplitude: float = lerpf(0.3, 0.7, _factor_smoothed)
	_update_draw_offset()
	draw_set_transform(draw_position + draw_offset)
	# Interior arc
	update_radial_gradient(color)
	gradient_texture.gradient.set_offset(1, lerpf(0.33, 0.5, _factor_smoothed))
	draw_sine_semicircle(radius - 2, amplitude, color, true)
	# Exterior arc
	draw_sine_semicircle(radius, amplitude)
	# Set particle emitter color
	particle_emitter.modulate = color

	# Adjust hitbox
	_hitbox.shape.size.y = lerpf(16, 30, factor)
	_hitbox.position.y = 64 - _hitbox.shape.size.y / 2


func draw_sine_semicircle(radius: float, amplitude: float = 1.0, color: Color = Color.WHITE, fill: bool = false, frequency: float = 12.0) -> void:
	var points: PackedVector2Array
	var uvs: PackedVector2Array
	amplitude *= radius * 0.1
	for sample: int in 91:
		var current_angle: float = deg_to_rad(sample * 2) + PI
		var current_radius: float = radius + (sin(current_angle * frequency - PI / 2) * amplitude)
		var pos: Vector2 = Vector2.from_angle(current_angle) * current_radius
		points.append(pos)
		if fill:
			uvs.append(pos / 128.0 + Vector2(0.5, 0.5))
	if fill:
		draw_polygon(points, [], uvs, gradient_texture)
	else:
		draw_polyline(points, color, 6.25, Config.anti_aliasing == Viewport.MSAA_DISABLED)


func _update_draw_offset() -> void:
	draw_offset.y = lerpf(
		draw_offset.y,
		float(_pad.get_overlapping_bodies().has(LevelManager.player)) * 22,
		get_process_delta_time() * 6,
	)
