class_name MusicScaleHitboxAttribute
extends MusicScaleAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var hitbox := parent.get_node_or_null(^"Hitbox")
	if not hitbox:
		return
	NodeUtils.get_node_or_add(hitbox, "MusicScale", MusicScale)


func _exit_tree() -> void:
	var hitbox := parent.get_node_or_null(^"Hitbox")
	if not hitbox:
		return
	hitbox.get_node_or_null(^"MusicScale").queue_free()
