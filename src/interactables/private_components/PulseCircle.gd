class_name PulseCircle
extends Node2D

const RADIUS := 128 * 1.25

@export var no_blending := false

var tween: Tween

@onready var parent := get_parent() as Interactable

var _radius: float = RADIUS:
	set(value):
		_radius = value
		queue_redraw()


func _ready() -> void:
	parent.interacted.connect(pulse)
	hide()
	modulate.a = 0.5
	if not no_blending:
		material = preload("res://resources/AdditiveBlendingMaterial.tres")


func _draw() -> void:
	var color: Color = $"../ParticleEmitter".modulate
	draw_circle(Vector2.ZERO, _radius, color, true, -1, true)


func pulse(_player: Player) -> void:
	if parent.has(NoEffectsComponent):
		return
	show()
	if tween:
		tween.kill()
	tween = create_tween().set_parallel()
	tween.tween_property(self, ^"_radius", 0.0, 0.25).from(RADIUS)
	await tween.finished
	hide()
