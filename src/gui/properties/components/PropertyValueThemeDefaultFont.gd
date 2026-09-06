extends Node
class_name PropertyValueThemeDefaultFont

@onready var parent: FileProperty = get_parent()


func _ready() -> void:
	if not parent.is_node_ready():
		await parent.ready
	var font_path: String = parent.get_theme_default_font().resource_path
	parent.default = font_path
