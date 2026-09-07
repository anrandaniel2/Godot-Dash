class_name TriggerGroupBoundingBox
extends Node2D

var bounding_boxes: Dictionary[Interactable, GroupBoundingBox]

@onready var saved_selection := Selection.new()


class GroupBoundingBox:
	var rect: Rect2
	var position: Vector2


	func _init(_rect: Rect2, _position: Vector2) -> void:
		rect = _rect
		position = _position


	func _to_string() -> String:
		return "[R: %s P: %s]" % [rect, position]


func _process(_delta: float) -> void:
	visible = not LevelManager.level_playing
	if saved_selection.is_empty() or LevelManager.level_playing:
		return
	update_bounding_boxes(saved_selection)
	queue_redraw()


func _draw() -> void:
	for interactable: Interactable in bounding_boxes:
		var bounding_box: GroupBoundingBox = bounding_boxes[interactable]
		draw_set_transform(bounding_box.position)
		draw_rect(bounding_box.rect, Color.GREEN, false, 4.0)
		var closest_point_on_rect: Vector2 = bounding_box.rect.get_support(interactable.global_position - bounding_box.position)
		draw_line(interactable.global_position - bounding_box.position, closest_point_on_rect, Color.GREEN, 4.0)


func update_bounding_boxes(selection: Selection) -> void:
	bounding_boxes.clear()
	for object: Node2D in selection.to_array():
		if object is Interactable and object.has(TargetGroupComponent):
			var interactable: Interactable = object
			var target_group: String = interactable.query(TargetGroupComponent).target_group
			if target_group.is_empty():
				continue
			var objects_in_group: Array[CollisionObject2D]
			objects_in_group.assign(
				get_tree() \
						.get_nodes_in_group(target_group) \
						.filter(func(group_object: Node): return group_object is CollisionObject2D or group_object is GDObject) \
						.map(EditHandler.get_object_selection_collider) \
						.filter(func(collider: Variant): return collider != null),
			)
			if objects_in_group.is_empty():
				continue
			var objects_center: Vector2 = ArrayUtils.transform(objects_in_group.map(func(group_object: Node2D): return group_object.global_position), ArrayUtils.Transformation.MEAN, true)
			bounding_boxes[interactable] = GroupBoundingBox.new(BoundingBox.new(objects_in_group, objects_center, 0.0).as_rect().grow(64.0), objects_center)


func _on_edit_handler_selection_changed(selection: Selection) -> void:
	saved_selection = selection
	# Clear the displayed bounding boxes
	if selection.is_empty():
		bounding_boxes.clear()
		queue_redraw()


func _on_level_operations_handler_level_loaded(_level: Level) -> void:
	saved_selection = Selection.EMPTY()
	bounding_boxes.clear()
	queue_redraw()
