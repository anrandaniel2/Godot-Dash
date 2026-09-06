extends EditorViewport

func _ready() -> void:
	Editor.viewport = self
	add_child(
		ScaleGizmo.new(
			Transform2D.IDENTITY.scaled_local(Vector2.ONE * 128.0),
			get_rect().get_center(),
			-deg_to_rad(20),
		),
	)
