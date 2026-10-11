class_name TeleportComponent
extends Component

enum VelocityModification {
	NONE,
	REDIRECT,
	OVERRIDE,
}

@export var axis: Constants.Axis
@export var velocity_modification: VelocityModification:
	set(value):
		velocity_modification = value
		notify_property_list_changed()
## Multiplier for the redirected velocity.
@export_range(-1.0, 1.0, 0.01, "or_less", "or_greater", "slider") var redirect_multiplier: float = 1.0
@export_custom(PROPERTY_HINT_NONE, "suffix:cells/s") var new_velocity: Vector2
@export var new_velocity_axes: Constants.Axis

@export_group("Geometry Dash")
## Group whose member is the exit (2.2 unlinked portal, teleport orb and
## trigger, key 51). Empty uses [TargetObjectComponent].
@export var target_group: String = ""
## 747 portal: the exit keeps the player's X (GD moves along Y only).
@export var keep_player_x: bool = false
@export var save_offset: bool = false
@export var ignore_x: bool = false
@export var ignore_y: bool = false
## 0 unchanged, 1 normal, 2 flipped, 3 toggle (key 354).
@export_range(0, 3) var gravity_mode: int = 0
@export var static_force_enabled: bool = false
@export var static_force: float = 0.0
@export var static_force_additive: bool = false
@export var redirect_force_enabled: bool = false
@export var redirect_force_mod: float = 1.0
@export var redirect_force_min: float = 0.0
@export var redirect_force_max: float = 0.0
@export var instant_camera: bool = false


func _ready() -> void:
	await require([TargetObjectComponent])
	if velocity_modification == VelocityModification.REDIRECT:
		parent.collision_layer |= 1 << 10 # Velocity redirectors
	parent.interacted.connect(teleport)
	$"../TargetLink".visible = Editor.in_editor


func _validate_property(property: Dictionary) -> void:
	if (
			(property.name == "redirect_multiplier" and velocity_modification != VelocityModification.REDIRECT)
			or (property.name in ["new_velocity", "new_velocity_axes"] and velocity_modification != VelocityModification.OVERRIDE)
	):
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"velocity_modification": VelocityModification.NONE,
		"redirect_multiplier": 1.0,
		"new_velocity": Vector2.ZERO,
		"new_velocity_axes": Constants.Axis.BOTH,
	}
	return DEFAULT_VALUES.get(property)


func teleport(player: Player) -> void:
	var target := _resolve_target()
	# Device forensics 2026-09-13: a teleport interaction with an unset target
	# has been observed firing at the exact moment the process dies at level
	# start. Log it (Toasts.error is UI-only and never reaches logcat).
	print("[gdash-tp] %s fired, target %s" % [parent.name, "set" if target else "UNSET"])
	if not target:
		if target_group.is_empty():
			Toasts.error("In %s: target is unset" % parent.name)
			return
	else:
		var destination := GDTeleport.destination(
			player.global_position, parent.global_position, GDTeleport.target_point(target),
			keep_player_x, save_offset, ignore_x, ignore_y,
		)
		match axis:
			Constants.Axis.BOTH:
				player.global_position = destination
			Constants.Axis.X:
				player.global_position.x = destination.x
			Constants.Axis.Y:
				player.global_position.y = destination.y
	_apply_gd_options(player, target)
	if not target:
		return
	match velocity_modification:
		VelocityModification.REDIRECT:
			var local_velocity_to_entrance := player.velocity.rotated(-parent.global_rotation)
			local_velocity_to_entrance.y *= -1
			var local_velocity_to_exit := local_velocity_to_entrance.rotated(target.global_rotation)
			player.velocity = local_velocity_to_exit
		VelocityModification.OVERRIDE:
			match new_velocity_axes:
				Constants.Axis.BOTH:
					player.set_deferred(&"velocity", (new_velocity * Constants.CELLS_TO_PX).rotated(player.gameplay_rotation))
				Constants.Axis.X:
					player.velocity = Vector2(
						(new_velocity * Constants.CELLS_TO_PX).x,
						player.velocity.rotated(-player.gameplay_rotation).y,
					).rotated(player.gameplay_rotation)
				Constants.Axis.Y:
					player.velocity = Vector2(
						player.velocity.rotated(-player.gameplay_rotation).x,
						(new_velocity * Constants.CELLS_TO_PX).y,
					).rotated(player.gameplay_rotation)
		VelocityModification.NONE:
			pass


func _resolve_target() -> Node2D:
	if target_group.is_empty():
		var target_component: TargetObjectComponent = parent.query(TargetObjectComponent)
		return target_component.target_to_node()
	var level: Node = LevelManager.current_level
	if not level:
		return null
	# GD picks a random member when the group has several; the first member is
	# used so replays stay deterministic (identical for one-member groups).
	for candidate: Node in get_tree().get_nodes_in_group(target_group):
		if candidate is Node2D and candidate != parent and level.is_ancestor_of(candidate):
			return candidate as Node2D
	return null


func _apply_gd_options(player: Player, target: Node2D) -> void:
	var portal_mode := GDTeleport.gravity_portal_mode(gravity_mode)
	if portal_mode >= 0:
		var flip := GDTeleport.gravity_flip(portal_mode, player.gravity_flip)
		if flip != player.gravity_flip:
			player.gravity_flip = flip
			player.queue_gravity_portal(flip)
	if redirect_force_enabled or static_force_enabled:
		var angle := GDTeleport.force_angle(
			target != null, int(parent.get_meta(&"gd_object_id", 0)),
			target.global_rotation_degrees if target else 0.0,
			parent.global_rotation_degrees, parent.scale.x < 0.0,
		)
		var local := player.velocity.rotated(-player.gameplay_rotation)
		var gd_velocity := Vector2(local.x, -local.y) / GDTeleport.GD_VELOCITY_TO_PX
		var result: Vector2
		if redirect_force_enabled:
			result = GDTeleport.redirect_velocity(angle, redirect_force_mod, redirect_force_min, redirect_force_max, gd_velocity, LevelManager.platformer)
		else:
			result = GDTeleport.static_velocity(angle, static_force, static_force_additive, gd_velocity, LevelManager.platformer)
		var new_local := Vector2(
			result.x * GDTeleport.GD_VELOCITY_TO_PX if LevelManager.platformer else local.x,
			-result.y * GDTeleport.GD_VELOCITY_TO_PX,
		)
		player.velocity = new_local.rotated(player.gameplay_rotation)
	if instant_camera and LevelManager.player_camera:
		LevelManager.player_camera.snap_view()
