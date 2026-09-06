class_name ColorChannelItem
extends PanelContainer

const COLOR_PREVIEW_DISABLED := Color("#00000080")

signal selected
signal unselected
signal deleted

@export var channel_name: String

var data: ColorChannelData


func _ready() -> void:
	update()


func update() -> void:
	var channel_name_label := %ChannelName as Label
	channel_name_label.text = channel_name
	if data == null:
		data = ColorChannelData.new()
	NodeUtils.connect_once(data.changed, update)
	data.associated_group = Constants.COLOR_CHANNEL_GROUP_PREFIX + channel_name
	if not data.copy:
		_set_color_preview_color(data.color)._hide_color_preview_text()
	else:
		match data.copied_channel:
			Constants.SpecialColorChannel.BACKGROUND:
				_disable_color_preview()._show_color_preview_text("BG")
			Constants.SpecialColorChannel.GROUND:
				_disable_color_preview()._show_color_preview_text("G")
			Constants.SpecialColorChannel.LINE:
				_disable_color_preview()._show_color_preview_text("L")
			Constants.SpecialColorChannel.P1:
				_disable_color_preview()._show_color_preview_text("P1")
			Constants.SpecialColorChannel.P2:
				_disable_color_preview()._show_color_preview_text("P2")
			Constants.SpecialColorChannel.GLOW:
				_disable_color_preview()._show_color_preview_text("GL")


func register() -> void:
	var level: Level = Editor.root.level
	var has_same_group := func(channel: ColorChannelData, group: String): return channel.associated_group == group
	var duplicates: Array[ColorChannelData]
	duplicates.assign(level.color_channels.filter(has_same_group.bind(data.associated_group)))
	if duplicates.is_empty():
		level.color_channels.append(data)
		level.add_child(ColorChannelWatcher.new(data))
		return
	data = duplicates.front()


func unregister() -> void:
	var level := LevelManager.current_level
	level.color_channels.erase(data)
	var watcher := get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + data.associated_group) as ColorChannelWatcher
	watcher.queue_free()


func set_pressed(pressed: bool) -> void:
	$EditButton.set_pressed(pressed)


func set_pressed_no_signal(pressed: bool) -> void:
	$EditButton.set_pressed_no_signal(pressed)


func is_pressed() -> bool:
	return $EditButton.button_pressed


func _set_color_preview_color(_color: Color) -> ColorChannelItem:
	var color_preview := %ColorPreview as PanelContainer
	var color_preview_stylebox := color_preview.get_theme_stylebox("panel") as StyleBoxFlat
	color_preview_stylebox.bg_color = _color
	return self


func _disable_color_preview() -> ColorChannelItem:
	var color_preview := %ColorPreview as PanelContainer
	var color_preview_stylebox := color_preview.get_theme_stylebox("panel") as StyleBoxFlat
	color_preview_stylebox.bg_color = COLOR_PREVIEW_DISABLED
	return self


func _show_color_preview_text(text: String) -> ColorChannelItem:
	var color_preview_text := %ColorPreviewText as Label
	color_preview_text.show()
	color_preview_text.text = text
	return self


func _hide_color_preview_text() -> ColorChannelItem:
	var color_preview_text := %ColorPreviewText as Label
	color_preview_text.hide()
	return self


func _on_delete_button_pressed() -> void:
	if $EditButton.button_pressed:
		unselected.emit()
	set_pressed_no_signal(false)
	deleted.emit()


func _on_edit_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		selected.emit()
	else:
		unselected.emit()
