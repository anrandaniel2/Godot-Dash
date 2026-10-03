@abstract
class_name ReboundSprite
extends Node2D

const GRADIENT: Gradient = preload("res://resources/gradients/rebound_gradient.tres")

@export var particle_emitter: GPUParticles2D

var visible_on_screen_notifier: VisibleOnScreenNotifier2D
var factor: float:
	set(value):
		factor = value
		_factor_smoothed = lerpf(_factor_smoothed, factor, get_process_delta_time() * 6)
		queue_redraw()
var _factor_smoothed: float

var gradient_texture: GradientTexture2D


func _ready() -> void:
	gradient_texture = GradientTexture2D.new()
	gradient_texture.set_gradient(Gradient.new())
	gradient_texture.set_fill(GradientTexture2D.FILL_RADIAL)
	gradient_texture.fill_from = Vector2(0.5, 0.5)
	visible_on_screen_notifier = VisibleOnScreenNotifier2D.new()
	visible_on_screen_notifier.rect = Rect2(Vector2(-77, -77), Vector2(154, 154))
	add_child(visible_on_screen_notifier)


func update_radial_gradient(color: Color) -> void:
	gradient_texture.gradient.set_color(0, color.lightened(lerpf(0.5, 0.25, _factor_smoothed)))
	gradient_texture.gradient.set_color(1, color)
