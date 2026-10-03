class_name SpeedChangerComponent
extends Component

@export var speed: float

var previous_player_speed: float


func _ready() -> void:
	parent.body_entered.connect(set_speed)


func set_speed(player: Player) -> void:
	player.speed_multiplier = speed
	if is_zero_approx(speed):
		player.speed_0_portal_control = parent
		player.displayed_gamemode = player.displayed_gamemode
		previous_player_speed = player.speed_multiplier
	if player == LevelManager.player_camera.player:
		LevelManager.player_camera.center_on_player_at_0x_speed = true
