class_name NoTouchAttribute
extends Attribute

@onready var parent := get_parent() as CollisionObject2D


func _ready() -> void:
	if parent is Area2D:
		parent.monitoring = false
		parent.monitorable = false
		return
	for shape_owner in parent.get_shape_owners():
		var collision_shape: CollisionShape2D = parent.shape_owner_get_owner(shape_owner)
		collision_shape.disabled = true


func _exit_tree() -> void:
	if not is_queued_for_deletion():
		return
	if parent is Area2D:
		parent.monitoring = true
		parent.monitorable = true
		return
	for shape_owner in parent.get_shape_owners():
		var collision_shape: CollisionShape2D = parent.shape_owner_get_owner(shape_owner)
		collision_shape.disabled = false
