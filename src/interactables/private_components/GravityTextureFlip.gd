class_name GravityTextureFlip
extends Node

@onready var sprite := get_parent() as Sprite2D

var _last_flip: bool


func _ready() -> void:
	_last_flip = LevelManager.player.gravity_flip < 0
	sprite.flip_v = _last_flip


func _process(_delta: float) -> void:
	# flip_v only ever changes when gravity actually flips; the old code set
	# the property (and read the player through the autoload) every frame for
	# every textured object carrying this component.
	var flip: bool = LevelManager.player.gravity_flip < 0
	if flip == _last_flip:
		return
	_last_flip = flip
	sprite.flip_v = flip
