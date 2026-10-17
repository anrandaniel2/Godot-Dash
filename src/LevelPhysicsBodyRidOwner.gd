extends Node2D
## Lightweight object-ID bridge for a body created through PhysicsServer2D.
## The scene node carries no collision shapes; its only role is to associate
## direct-server collision results with the LevelPhysics shape-index metadata.

var physics_rid: RID


func bind_physics_rid(rid: RID) -> void:
	physics_rid = rid
	set_notify_transform(true)
	_sync_server_state()


func unbind_physics_rid() -> void:
	physics_rid = RID()
	set_notify_transform(false)


func set_server_shape_disabled(shape_index: int, disabled: bool) -> void:
	if physics_rid.is_valid():
		PhysicsServer2D.body_set_shape_disabled(physics_rid, shape_index, disabled)


func _notification(what: int) -> void:
	if not physics_rid.is_valid():
		return
	match what:
		NOTIFICATION_ENTER_TREE, NOTIFICATION_WORLD_2D_CHANGED:
			_sync_server_state()
		NOTIFICATION_TRANSFORM_CHANGED, NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
			PhysicsServer2D.body_set_state(
				physics_rid, PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform
			)
		NOTIFICATION_EXIT_TREE:
			PhysicsServer2D.body_set_space(physics_rid, RID())
		NOTIFICATION_PREDELETE:
			PhysicsServer2D.free_rid(physics_rid)
			physics_rid = RID()


func _sync_server_state() -> void:
	if not physics_rid.is_valid():
		return
	var space := get_world_2d().space if is_inside_tree() and get_world_2d() != null else RID()
	PhysicsServer2D.body_set_space(physics_rid, space)
	PhysicsServer2D.body_set_state(
		physics_rid, PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform
	)
