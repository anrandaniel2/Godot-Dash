class_name NinePatchSprite2DAbsoluteSize
extends Node

@export var nine_patch_sprite: NinePatchSprite2D
@onready var parent := get_parent() as Node2D


func _ready() -> void:
	update_size()


func update_size() -> void:
	nine_patch_sprite.global_scale = Vector2(0.25, 0.25)
	nine_patch_sprite.size = abs(parent.global_scale) * Vector2(512, 512)
