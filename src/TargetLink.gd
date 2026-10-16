@tool
class_name TargetLink
extends Line2D

var target: Node2D
var target_component: TargetObjectComponent
var _last_visible: bool


func _ready() -> void:
	target_component = NodeUtils.get_child_of_type(get_parent(), TargetObjectComponent)
	z_index = -50
	_last_visible = visible
	visibility_changed.connect(_on_visibility_changed)
	set_process(_last_visible)


func _on_visibility_changed() -> void:
	# Ignore inherited visibility notifications: the original callback gates
	# on this node's `visible` property, not its ancestors' visibility.
	if visible == _last_visible:
		return
	_last_visible = visible
	# The old per-frame hidden branch cleared these points. Clear on both
	# transitions so a later show cannot reveal stale geometry.
	clear_points()
	set_process(_last_visible)


func _process(delta: float) -> void:
	if not visible:
		clear_points()
		return
	if target_component == null:
		clear_points()
		return
	target = target_component.target_to_node()
	if target == null:
		clear_points()
		return
	if get_point_count() > 0 and get_point_position(1) != target.global_position:
		clear_points()
		add_point(to_local(target.global_position), 0)
		add_point(Vector2.ZERO, 1)
	elif get_point_count() > 2:
		clear_points()
	if not Engine.is_editor_hint():
		var camera_rect := GameScene.get_camera_rect(get_viewport().get_camera_2d(), get_viewport())
		var parent_visible := camera_rect.has_point(get_parent().global_position)
		var target_visible := camera_rect.has_point(target.global_position)
		var alpha: float = 0.0
		if parent_visible != target_visible: # xor
			alpha = 0.25
		elif parent_visible and target_visible:
			alpha = 1.0
		alpha = remap(alpha, 0.0, 1.0, 0.25, 1.0)
		modulate.a = lerpf(modulate.a, alpha, delta * 12)
	if LevelManager.level_playing or (not Engine.is_editor_hint() and not (Editor.in_editor or get_tree().is_debugging_collisions_hint())):
		hide()
