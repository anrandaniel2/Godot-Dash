class_name MusicScaleDetailAttribute
extends MusicScaleAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var detail := parent.get_node_or_null(^"Detail")
	if not detail:
		return
	NodeUtils.get_node_or_add(detail, "MusicScale", MusicScale)
	if detail is NinePatchSprite2D:
		var absolute := parent.get_node_or_null("NinePatchSprite2DAbsoluteSize")
		if absolute:
			absolute.process_mode = Node.PROCESS_MODE_DISABLED


func _exit_tree() -> void:
	var detail := parent.get_node_or_null(^"Detail")
	if not detail:
		return
	detail.get_node_or_null(^"MusicScale").queue_free()
	if detail is NinePatchSprite2D:
		var absolute := parent.get_node_or_null("NinePatchSprite2DAbsoluteSize")
		if absolute:
			absolute.process_mode = Node.PROCESS_MODE_INHERIT
