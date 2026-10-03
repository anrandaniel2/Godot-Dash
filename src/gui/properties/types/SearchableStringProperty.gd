@tool
class_name SearchableStringProperty
extends Property

signal value_changed(value: String)
signal interaction_ended(value: String, previous: String)

@export var default: String
@export var placeholder: String
@export var select_all_on_focus: bool
@export var suggestion_provider: SuggestionProvider:
	set(value):
		suggestion_provider = value
		update_configuration_warnings()

@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var suggestion_panel: PanelContainer
var suggestion_list: ItemList
var input: LineEdit
var _previous_text: String


func _get_configuration_warnings() -> PackedStringArray:
	if not suggestion_provider:
		return ["SuggestionProvider is required."]
	return []


func _ready() -> void:
	if not Engine.is_editor_hint():
		assert(suggestion_provider, "missing SuggestionProvider")

	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", LineEdit, NodeUtils.INTERNAL)
	suggestion_panel = NodeUtils.get_node_or_add(self, "SuggestionPanel", PanelContainer, NodeUtils.INTERNAL)
	suggestion_list = NodeUtils.get_node_or_add(suggestion_panel, "SuggestionList", ItemList, NodeUtils.INTERNAL)

	suggestion_panel.material = preload("res://resources/SimpleBlurMaterial.tres")
	suggestion_panel.top_level = true
	suggestion_list.focus_mode = Control.FOCUS_NONE
	suggestion_list.item_clicked.connect(_on_suggestion_selected)
	suggestion_list.scroll_hint_mode = ItemList.SCROLL_HINT_MODE_BOTH
	suggestion_list.auto_height = true

	suggestion_panel.visible = suggestion_list.item_count > 0

	input.text_changed.connect(_on_text_changed)
	input.text_submitted.connect(_on_text_submitted)
	input.editing_toggled.connect(_on_editing_toggled)
	input.focus_entered.connect(
		func():
			_update_suggestions(input.text)
	)
	input.focus_exited.connect(
		func():
			if suggestion_panel.visible:
				suggestion_panel.hide()
	)
	input.gui_input.connect(_on_input_gui_input)

	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func _process(_delta: float) -> void:
	suggestion_panel.custom_minimum_size.x = input.size.x
	suggestion_panel.global_position = input.global_position + Vector2(0, input.size.y)


func set_value(new_value: String) -> void:
	set_value_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: String) -> void:
	_value = new_value
	input.set_text(new_value)


func get_value() -> String:
	return input.get_text()


func reset() -> void:
	set_value(default)
	suggestion_panel.hide()
	suggestion_list.clear()


func refresh() -> void:
	label.text = name
	input.focus_mode = Control.FOCUS_CLICK
	input.placeholder_text = placeholder
	input.select_all_on_focus = select_all_on_focus
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.editable = enabled


func _on_editing_toggled(toggled_on: bool):
	suggestion_panel.visible = toggled_on
	unedit_release_focus(toggled_on)
	if toggled_on:
		_previous_text = input.text
		_update_suggestions(input.text)


func _on_text_changed(new_text: String) -> void:
	value_changed.emit(new_text)
	_update_suggestions(new_text)


func _on_text_submitted(new_text: String) -> void:
	interaction_ended.emit(new_text, _previous_text)
	suggestion_panel.hide()
	submitted_release_focus(new_text)


func _on_suggestion_selected(index: int, _at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var selected_text = suggestion_list.get_item_text(index)
	set_value(selected_text)
	input.caret_column = selected_text.length()
	_on_text_submitted(selected_text)


func _on_input_gui_input(event: InputEvent) -> void:
	if not suggestion_panel.visible or suggestion_list.item_count == 0:
		return

	if event is InputEventKey and event.is_pressed():
		var current_index = -1
		if not suggestion_list.get_selected_items().is_empty():
			current_index = suggestion_list.get_selected_items()[0]

		var new_index = current_index

		# Next Item: Down Arrow or Tab
		if event.keycode == KEY_DOWN or (event.keycode == KEY_TAB and not event.shift_pressed):
			new_index = posmod(current_index + 1, suggestion_list.item_count)
			input.accept_event() # Consumes the event so the LineEdit doesn't process it

		# Previous Item: Up Arrow or Shift+Tab
		elif event.keycode == KEY_UP or (event.keycode == KEY_TAB and event.shift_pressed):
			new_index = suggestion_list.item_count - 1 if current_index == -1 else posmod(current_index - 1, suggestion_list.item_count)
			input.accept_event()

		# Confirm Selection: Enter
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if current_index != -1:
				_on_suggestion_selected(current_index, Vector2.ZERO, MOUSE_BUTTON_LEFT)
				input.accept_event()
			return

		# Update the visual selection
		if new_index != current_index:
			suggestion_list.select(new_index)
			suggestion_list.ensure_current_is_visible()


func _update_suggestions(input_text: String) -> void:
	if not is_inside_tree():
		suggestion_panel.hide()
		return

	var suggestions: Array[String] = suggestion_provider.get_suggestions(input_text)
	suggestion_list.clear()
	for suggestion in suggestions:
		suggestion_list.add_item(suggestion)

	suggestion_panel.visible = suggestion_list.item_count > 0
	if suggestion_panel.visible:
		_refresh_list_height.call_deferred()


func _refresh_list_height() -> void:
	suggestion_list.size.y = 0
	# The list's height is recalculated
	suggestion_panel.size.y = suggestion_list.size.y
