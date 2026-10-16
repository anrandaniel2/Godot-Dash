class_name GravityTextureFlip
extends Node

@onready var sprite := get_parent() as Sprite2D

var _last_flip: bool
var _player: Player


func _ready() -> void:
	_player = LevelManager.player
	_last_flip = _player.gravity_flip < 0
	sprite.flip_v = _last_flip
	_player.gravity_flip_changed.connect(_on_gravity_flip_changed)
	set_process(false)


func _on_gravity_flip_changed(flip_value: int) -> void:
	var flip: bool = flip_value < 0
	if flip == _last_flip:
		return
	_last_flip = flip
	sprite.flip_v = flip
