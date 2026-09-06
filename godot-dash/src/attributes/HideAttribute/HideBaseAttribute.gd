class_name HideBaseAttribute
extends HideAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var base := parent.get_node_or_null(^"Base")
	if base:
		base.hide()


func _exit_tree() -> void:
	var base := parent.get_node_or_null(^"Base")
	if base:
		base.show()
