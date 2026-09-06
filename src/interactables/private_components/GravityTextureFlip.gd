class_name GravityTextureFlip
extends Node

@onready var sprite := get_parent() as Sprite2D


func _process(_delta: float) -> void:
	sprite.flip_v = LevelManager.player.gravity_flip < 0
