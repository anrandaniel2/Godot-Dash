class_name PulseScale
extends Node

@export var sprite: Node2D

@onready var parent := get_parent() as Interactable

var tween: Tween
var default_sprite_scale: Vector2


func _ready() -> void:
	parent.interacted.connect(pulse_scale)
	default_sprite_scale = sprite.scale


func pulse_scale(_player: Player) -> void:
	var music_scale: MusicScale = NodeUtils.get_child_of_type(sprite, MusicScale)
	if music_scale:
		music_scale.disabled = true
		default_sprite_scale = music_scale.initial_scale

	if tween:
		tween.kill()

	tween = create_tween().set_trans(Tween.TRANS_QUAD)
	tween.tween_property(sprite, ^"scale", default_sprite_scale * 1.2, 0.25).from(default_sprite_scale * Vector2(-1.0, 1.0)).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, ^"scale", default_sprite_scale * 0.7, 0.25).set_ease(Tween.EASE_IN_OUT)

	if music_scale:
		music_scale.disabled = false
