class_name TextSettings
extends LabelSettings

@export var _font_path: String:
	set = set_font_path

var prevent_history_action: bool = false
## Size and outline to restore when a GD bitmap font is swapped out again.
var _vector_font_size: int = -1
var _vector_outline_size: int = -1


func set_font_path(path: String = "") -> void:
	if not (path.is_empty() or path != _font_path):
		return
	var is_changing_default_font: bool = path.is_empty() and _font_path.is_empty()
	if LevelManager.current_level and path.is_empty():
		if is_changing_default_font:
			prevent_history_action = true
			changed.connect(
				func(): prevent_history_action = false,
				CONNECT_DEFERRED | CONNECT_ONE_SHOT,
			)
		font = AssetManager.load_font(LevelManager.current_level.default_font)
		var default_font_changed: Signal = LevelManager.current_level.default_font_changed
		if not default_font_changed.is_connected(set_font_path):
			default_font_changed.connect(set_font_path, CONNECT_DEFERRED)
	else:
		if not (path.is_empty() or path.begins_with("res://")) and LevelManager.current_level:
			LevelManager.current_level.register_required_font(_font_path, path)
			var default_font_changed: Signal = LevelManager.current_level.default_font_changed
			if default_font_changed.is_connected(set_font_path):
				default_font_changed.disconnect(set_font_path)
		font = AssetManager.load_font(path)
	_font_path = path
	_apply_gd_bitmap_metrics()


## GD text objects draw the HD BMFont at half scale in GD points (30 per
## cell, GD 2.2 TextGameObject over CCLabelBMFont), and its glyphs carry
## their own outline, so the label adds none.
func _apply_gd_bitmap_metrics() -> void:
	var file: FontFile = font as FontFile
	var is_gd_bitmap: bool = file != null and bool(file.get_meta(&"gd_bitmap", false))
	if is_gd_bitmap:
		if _vector_font_size < 0:
			_vector_font_size = font_size
			_vector_outline_size = outline_size
		file.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
		font_size = roundi(file.fixed_size * 0.5 / GMDConverter.GD_CELL_SIZE * Constants.CELL_SIZE)
		outline_size = 0
	elif _vector_font_size >= 0:
		font_size = _vector_font_size
		outline_size = _vector_outline_size
		_vector_font_size = -1
		_vector_outline_size = -1


func to_data() -> Dictionary:
	return {
		"line_spacing": line_spacing,
		"paragraph_spacing": paragraph_spacing,
		"font_size": font_size,
		"font_color": font_color,
		"outline_size": outline_size,
		"outline_color": outline_color,
		"shadow_size": shadow_size,
		"shadow_color": shadow_color,
		"shadow_offset": shadow_offset,
		"_font_path": _font_path if not _font_path.begins_with("res://") else "",
	}


static func from_data(data: Dictionary) -> TextSettings:
	var text_settings := TextSettings.new()
	text_settings._font_path = data._font_path
	text_settings.line_spacing = data.line_spacing
	text_settings.paragraph_spacing = data.paragraph_spacing
	text_settings.font_size = data.font_size
	text_settings.font_color = data.font_color
	text_settings.outline_size = data.outline_size
	text_settings.outline_color = data.outline_color
	text_settings.shadow_size = data.shadow_size
	text_settings.shadow_color = data.shadow_color
	text_settings.shadow_offset = data.shadow_offset
	return text_settings
