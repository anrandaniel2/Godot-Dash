class_name TextComponent
extends Component

const DEFAULT_TEXT_SETTINGS: TextSettings = preload("res://resources/DefaultTextSettings.tres")

@export_multiline var text: String:
	set(value):
		text = value
		if _label:
			_label.text = value if not value.is_empty() else "Aa"
			update_label_size.call_deferred()
@export var horizontal_alignment: HorizontalAlignment:
	set(value):
		horizontal_alignment = value
		if _label:
			_label.horizontal_alignment = value
			update_label_size.call_deferred()
@export var vertical_alignment: VerticalAlignment:
	set(value):
		vertical_alignment = value
		if _label:
			_label.vertical_alignment = value
			update_label_size.call_deferred()
@export var settings: TextSettings:
	set(value):
		settings = value if value else DEFAULT_TEXT_SETTINGS
		refresh_label_settings()
@export var _label: Label
@export var _selection_collider: EditorSelectionCollider


func _init() -> void:
	settings = DEFAULT_TEXT_SETTINGS
	settings.changed.connect(refresh_label_settings)


func refresh_label_settings() -> void:
	if not _label:
		return
	_label.label_settings = settings
	if not text.is_empty():
		update_label_size.call_deferred()


func update_label_size() -> void:
	if not _label:
		return
	_label.size = _label.get_minimum_size()
	match horizontal_alignment:
		HORIZONTAL_ALIGNMENT_LEFT:
			_label.position.x = 0.0
		HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_FILL:
			_label.position.x = -_label.size.x / 2.0
		HORIZONTAL_ALIGNMENT_RIGHT:
			_label.position.x = -_label.size.x
	match vertical_alignment:
		VERTICAL_ALIGNMENT_TOP:
			_label.position.y = 0.0
		VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_FILL:
			_label.position.y = -_label.size.y / 2.0
		VERTICAL_ALIGNMENT_BOTTOM:
			_label.position.y = -_label.size.y
	_selection_collider.scale = _label.size / (Vector2.ONE * Constants.CELL_SIZE)
	_selection_collider.position = _label.get_rect().get_center()


func _field_to_data(field_name: String, _reason: Serialize.Reason) -> Variant:
	match field_name:
		"settings":
			return (settings if settings else DEFAULT_TEXT_SETTINGS).to_data()
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	if field_name == "settings":
		settings = TextSettings.from_data(field_data)
		return
	set(field_name, field_data)
