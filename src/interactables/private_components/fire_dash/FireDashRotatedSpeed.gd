class_name FireDashRotatedSpeed
extends FireDashSpeed

func get_velocity(player: Player, fire_dash_component: FireDashComponent) -> Vector2:
	var dash_orb: Interactable = fire_dash_component.parent
	var angle: float = dash_orb.global_rotation - fire_dash_component.initial_gameplay_rotation
	var velocity: Vector2 = Vector2(player.speed.x * player.speed_multiplier, 0.0).rotated(angle)
	return velocity
