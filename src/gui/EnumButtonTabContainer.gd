class_name EnumButtonTabContainer
extends BoxContainer

func _on_enum_button_value_changed(variant_index: int) -> void:
	for i in get_child_count():
		get_child(i).visible = i == variant_index
