class_name HideDetailAttribute
extends HideAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var detail := parent.get_node_or_null(^"Detail")
	if detail:
		detail.hide()


func _exit_tree() -> void:
	var detail := parent.get_node_or_null(^"Detail")
	if detail:
		detail.show()
