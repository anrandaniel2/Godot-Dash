class_name PulseRing
extends Node2D

var tween: Tween

var _radius: float:
	set(value):
		_radius = value
		queue_redraw()
var _alpha := 1.0

@onready var parent := get_parent() as OrbInteractable


func _ready() -> void:
	hide()
	parent.body_entered.connect(pulse)


func pulse(_player: Player) -> void:
	if parent.has(NoEffectsComponent):
		return
	show()
	if tween:
		tween.kill()
	tween = create_tween().set_parallel()
	tween.tween_property(self, ^"_radius", 128 * 1.5, 0.25).from(0.0)
	tween.tween_property(self, ^"_alpha", 0.0, 0.25).from(1.0)
	await tween.finished
	hide()


func _draw() -> void:
	var color := Color.WHITE
	color.a = _alpha
	draw_circle(Vector2.ZERO, _radius, color, false, 2, true)
