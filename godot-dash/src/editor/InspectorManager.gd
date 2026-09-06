class_name InspectorManager
extends Node

signal renamed_object(object: Node2D, new_name: String)

enum InspectorTab {
	LEVEL,
	OBJECT,
	INTERACTABLE,
	PHYSICS,
	COLORS,
	NONE,
}

@export var panel_container: PanelContainer
@export var tab_bar: EnumButton
@export var tree: Tree
@export var object_name: LineEdit

@export_group("Level")
@export var level_settings: LevelSettings

@export_group("Object")
@export var group_parent: BoolProperty
@export var attributes_section: FoldableContainer

@export_group("Interactable")
@export var interactable_editor: InteractableEditor

@export_group("Colors")
@export var object_color_properties: VBoxContainer
@export var hsv_shift: FoldableContainer

var force_switched_previous_tab: InspectorTab = InspectorTab.NONE


func _ready() -> void:
	object_name.text_submitted.connect(update_object_name)
	interactable_editor.object_name.text_submitted.connect(update_object_name)
	group_parent.value_changed.connect(_on_group_parent_value_changed)
	_on_edit_handler_selection_changed(Selection.EMPTY())


func _on_edit_handler_selection_changed(selection: Selection) -> void:
	object_name.visible = not selection.is_empty()
	if selection.size() == 1:
		object_name.text = selection.first().name
		interactable_editor.object_name.text = selection.first().name
		object_name.editable = selection.first() is not Player
		interactable_editor.object_name.editable = selection.first() is not Player
		group_parent.set_value_no_signal(selection.first().has_meta("group_parent"))
		group_parent.set_input_state(true)
		attributes_section.visible = selection.first() is not Player
	elif selection.size() > 1:
		object_name.text = "%s %s" % [
			selection.size(),
			(
				"objects"
				if not selection.map(InteractableEditor.player_to_interactable).all(InteractableEditor.is_interactable)
				else "interactables"
			),
		]
		interactable_editor.object_name.text = object_name.text
		object_name.editable = false
		interactable_editor.object_name.editable = false
		group_parent.set_value_no_signal(false)
		group_parent.set_input_state(false)
		attributes_section.show()

	object_color_properties.visible = not (selection.is_empty() or (selection.size() == 1 and selection.first() is Player))
	if selection.size() == 1 and selection.first() is Player:
		hsv_shift.visible = true

	var selection_is_empty: bool = selection.is_empty()
	var is_solid_object := func(object: Node2D): return object is SolidObject
	var selection_is_interactable: bool = not selection_is_empty and selection.map(InteractableEditor.player_to_interactable).all(InteractableEditor.is_interactable)
	var selection_is_solid_object: bool = not selection_is_empty and selection.all(is_solid_object)

	tab_bar.set_tab_visibility(InspectorTab.OBJECT, not selection_is_empty)
	tab_bar.set_tab_visibility(InspectorTab.INTERACTABLE, selection_is_interactable)
	tab_bar.set_tab_visibility(InspectorTab.PHYSICS, selection_is_solid_object)

	if force_switched_previous_tab != InspectorTab.NONE:
		match force_switched_previous_tab:
			InspectorTab.INTERACTABLE when selection_is_interactable:
				tab_bar.set_value(InspectorTab.INTERACTABLE)
			InspectorTab.PHYSICS when selection_is_solid_object:
				tab_bar.set_value(InspectorTab.PHYSICS)
			InspectorTab.OBJECT when not selection_is_empty:
				tab_bar.set_value(InspectorTab.OBJECT)
		force_switched_previous_tab = InspectorTab.NONE

	match tab_bar.get_value():
		InspectorTab.OBJECT, InspectorTab.INTERACTABLE, InspectorTab.PHYSICS when selection_is_empty:
			force_switched_previous_tab = tab_bar.get_value() as InspectorTab
			tab_bar.set_value(InspectorTab.LEVEL)
			tab_bar.value_changed.connect(_reset_force_switched_previous_tab, CONNECT_ONE_SHOT)
		InspectorTab.INTERACTABLE when not selection_is_interactable:
			force_switched_previous_tab = InspectorTab.INTERACTABLE
			tab_bar.set_value(InspectorTab.OBJECT)
			tab_bar.value_changed.connect(_reset_force_switched_previous_tab, CONNECT_ONE_SHOT)
		InspectorTab.PHYSICS when not selection_is_solid_object:
			force_switched_previous_tab = InspectorTab.PHYSICS
			tab_bar.set_value(InspectorTab.OBJECT)
			tab_bar.value_changed.connect(_reset_force_switched_previous_tab, CONNECT_ONE_SHOT)


func update_object_name(new_name: String):
	var object: Node2D = $"../EditHandler".selection.first()
	var previous_name: String = object.name
	var sanitized_new_name: String = new_name.validate_node_name()
	Editor.version_history.create_action("Renamed object %s to %s" % [previous_name, sanitized_new_name])
	Editor.version_history.add_do_method(
		func():
			object.name = sanitized_new_name
			object_name.text = sanitized_new_name
			interactable_editor.object_name.text = sanitized_new_name
			renamed_object.emit(object, sanitized_new_name)
	)
	Editor.version_history.add_undo_method(
		func():
			object.name = sanitized_new_name
			object_name.text = previous_name
			interactable_editor.object_name.text = previous_name
			renamed_object.emit(object, previous_name)
	)
	Editor.version_history.commit_action()
	get_viewport().gui_release_focus() # Restore editor keybinds


func _reset_force_switched_previous_tab(_new_tab: int) -> void:
	force_switched_previous_tab = InspectorTab.NONE


func _on_group_parent_value_changed(value: bool) -> void:
	var selection = $"../EditHandler".selection
	if selection.size() != 1:
		return
	if value:
		selection[0].set_meta("group_parent", true)
	else:
		selection[0].remove_meta("group_parent")
