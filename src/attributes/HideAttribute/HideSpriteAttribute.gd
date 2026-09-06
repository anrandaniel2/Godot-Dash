class_name HideSpriteAttribute
extends HideAttribute

@onready var parent := get_parent()


func _ready() -> void:
	for child in parent.get_children():
		if NodeUtils.is_valid_sprite(child):
			child.hide()


func _exit_tree() -> void:
	for child in parent.get_children():
		if NodeUtils.is_valid_sprite(child):
			child.show()
