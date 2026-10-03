class_name MusicScaleBaseAttribute
extends MusicScaleAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var base := parent.get_node_or_null(^"Base")
	if not base:
		return
	NodeUtils.get_node_or_add(base, "MusicScale", MusicScale)
	if base is NinePatchSprite2D:
		var absolute := parent.get_node_or_null("NinePatchSprite2DAbsoluteSize")
		if absolute:
			absolute.process_mode = Node.PROCESS_MODE_DISABLED


func _exit_tree() -> void:
	var base := parent.get_node_or_null(^"Base")
	if not base:
		return
	base.get_node_or_null(^"MusicScale").queue_free()
	if base is NinePatchSprite2D:
		var absolute := parent.get_node_or_null("NinePatchSprite2DAbsoluteSize")
		if absolute:
			absolute.process_mode = Node.PROCESS_MODE_INHERIT
