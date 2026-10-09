class_name SpeedChangerComponent
extends Component

@export var speed: float

var previous_player_speed: float


func _ready() -> void:
	parent.body_entered.connect(set_speed)
	_axis_align_hitbox.call_deferred()


## GD tests portals against GameObject::getObjectRect(), the axis-aligned box
## around the rotated sprite; its oriented-box pass compares the object's box
## with itself, so it never rejects (camila314 checkCollisions.cpp
## reconstruction, PlayLayer::checkCollisions). A 45-degree portal therefore
## catches the player across its whole enclosing square, not a thin diamond.
func _axis_align_hitbox() -> void:
	var area: Area2D = parent as Area2D
	if area == null or not area.is_inside_tree():
		return
	var shape_node: CollisionShape2D = area.get_node_or_null(^"Hitbox") as CollisionShape2D
	if shape_node == null or not (shape_node.shape is RectangleShape2D):
		return
	var angle: float = fposmod(area.global_rotation, PI / 2.0)
	if angle < 0.001 or PI / 2.0 - angle < 0.001:
		return
	var rotation_cos: float = absf(cos(area.global_rotation))
	var rotation_sin: float = absf(sin(area.global_rotation))
	var size: Vector2 = (shape_node.shape as RectangleShape2D).size * shape_node.scale.abs()
	var enclosing := RectangleShape2D.new()
	enclosing.size = Vector2(
			size.x * rotation_cos + size.y * rotation_sin,
			size.x * rotation_sin + size.y * rotation_cos,
	)
	shape_node.shape = enclosing
	shape_node.scale = Vector2.ONE
	shape_node.global_rotation = 0.0


func set_speed(player: Player) -> void:
	player.speed_multiplier = speed
	if is_zero_approx(speed):
		player.speed_0_portal_control = parent
		player.displayed_gamemode = player.displayed_gamemode
		previous_player_speed = player.speed_multiplier
	if player == LevelManager.player_camera.player:
		LevelManager.player_camera.center_on_player_at_0x_speed = true
