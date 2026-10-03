class_name FireDashTangentSpeed
extends FireDashSpeed

func get_velocity(player: Player, fire_dash_component: FireDashComponent) -> Vector2:
	var dash_orb: Interactable = fire_dash_component.parent
	var angle: float = dash_orb.rotation - fire_dash_component.initial_gameplay_rotation
	if player.speed_multiplier == 0.0 and fire_dash_component.initial_speed == 0.0:
		angle -= PI / 4
	var direction: int = (
			player.horizontal_direction
			if not LevelManager.platformer
			else int(sign(cos(dash_orb.rotation - fire_dash_component.initial_gameplay_rotation)))
	)
	var velocity: Vector2
	if (player.is_on_floor() and sin(angle) > 0) or (player.is_on_ceiling() and sin(angle) < 0):
		velocity.y = 0
	else:
		if not LevelManager.platformer:
			angle = -clampf(pingpong(angle - PI / 2, PI) - PI / 2, deg_to_rad(-70), deg_to_rad(70))
		velocity.y = tan(angle) * player.speed.x * direction * (player.speed_multiplier if player.speed_multiplier > 0.0 else 1.0)
	velocity.x = player.speed.x * direction * player.speed_multiplier
	return velocity
