class_name PhysicsEditor
extends VBoxContainer

@onready var parent: Node = get_parent()

@export var physics_object_property: BoolProperty
@export var mass_property: FloatProperty
@export var friction_property: FloatProperty
@export var rough_property: BoolProperty
@export var bounce_property: FloatProperty
@export var absorbent_property: BoolProperty
@export var gravity_scale_property: FloatProperty
@export var pushable_by_player_property: BoolProperty

var solid_objects: Selection = Selection.new()


func _on_edit_handler_selection_changed(_selection: Selection) -> void:
	solid_objects = _selection.filter(func(object): return object is SolidObject)
	if solid_objects.is_empty():
		return
	update()


func update() -> void:
	var data: Dictionary = solid_objects.first().get_data()
	physics_object_property.set_value_no_signal(data.physics_object)
	mass_property.set_value_no_signal(data.mass)
	friction_property.set_value_no_signal(data.friction)
	rough_property.set_value_no_signal(data.rough)
	bounce_property.set_value_no_signal(data.bounce)
	absorbent_property.set_value_no_signal(data.absorbent)
	gravity_scale_property.set_value_no_signal(data.gravity_scale)
	pushable_by_player_property.set_value_no_signal(data.pushable_by_player)


func _on_physics_object_value_changed(value: bool) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.physics_object = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, bool]):
		for path: NodePath in values:
			Editor.root.get_node(path).physics_object = values[path]
		update()
	var old_values: Dictionary[NodePath, bool]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.physics_object
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set physics object to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_mass_value_changed(value: float) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.mass = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, float]):
		for path: NodePath in values:
			Editor.root.get_node(path).mass = values[path]
		update()
	var old_values: Dictionary[NodePath, float]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.mass
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set mass to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_friction_value_changed(value: float) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: RigidBody2D):
				object.friction = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, float]):
		for path: NodePath in values:
			Editor.root.get_node(path).friction = values[path]
		update()
	var old_values: Dictionary[NodePath, float]
	solid_objects.for_each(
		func(object: RigidBody2D):
			old_values[Editor.root.get_path_to(object)] = object.friction
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set friction to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_rough_value_changed(value: bool) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.rough = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, bool]):
		for path: NodePath in values:
			Editor.root.get_node(path).component.rough = values[path]
		update()
	var old_values: Dictionary[NodePath, bool]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.rough
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set rough to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_bounce_value_changed(value: float) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.bounce = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, float]):
		for path: NodePath in values:
			Editor.root.get_node(path).bounce = values[path]
		update()
	var old_values: Dictionary[NodePath, float]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.bounce
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set bounce to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_absorbent_value_changed(value: bool) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.absorbent = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, bool]):
		for path: NodePath in values:
			Editor.root.get_node(path).absorbent = values[path]
		update()
	var old_values: Dictionary[NodePath, bool]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.absorbent
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set absorbent to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_gravity_scale_value_changed(value: float) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.gravity_scale = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, float]):
		for path: NodePath in values:
			Editor.root.get_node(path).gravity_scale = values[path]
		update()
	var old_values: Dictionary[NodePath, float]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.gravity_scale
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set gravity scale to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()


func _on_pushable_by_player_value_changed(value: bool) -> void:
	if solid_objects.is_empty():
		return
	var do_change_value := func(selection: Selection):
		selection.for_each(
			func(object: SolidObject):
				object.pushable_by_player = value
		)
		update()
	var undo_change_value := func(values: Dictionary[NodePath, bool]):
		for path: NodePath in values:
			Editor.root.get_node(path).component.pushable_by_player = values[path]
		update()
	var old_values: Dictionary[NodePath, bool]
	solid_objects.for_each(
		func(object: SolidObject):
			old_values[Editor.root.get_path_to(object)] = object.pushable_by_player
	)
	var selection_snapshot: Selection = solid_objects.clone()
	var selection_snapshot_size: int = selection_snapshot.size()
	Editor.version_history.create_action("Set pushable by player to %s on %s objects" % [value, selection_snapshot_size])
	Editor.version_history.add_do_method(do_change_value.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_change_value.bind(old_values))
	Editor.version_history.commit_action()
