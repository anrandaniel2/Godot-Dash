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
	var target_component: TargetObjectComponent = parent.query(TargetObjectComponent)
	var target := target_component.target_to_node()
	if not target:
		Toasts.error("In %s: target is unset" % parent.name)
		return
	match axis:
		Constants.Axis.BOTH:
			player.global_position = target.global_position
		Constants.Axis.X:
			player.global_position.x = target.global_position.x
		Constants.Axis.Y:
			player.global_position.y = target.global_position.y
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
