class_name FireDashSpeedPlatformerSwitch
extends FireDashSpeed

@export var sidescroller: FireDashSpeed
@export var platformer: FireDashSpeed


func get_velocity(player: Player, fire_dash_component: FireDashComponent) -> Vector2:
	if LevelManager.platformer:
		return platformer.get_velocity(player, fire_dash_component)
	else:
		return sidescroller.get_velocity(player, fire_dash_component)
