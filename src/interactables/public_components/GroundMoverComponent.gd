@tool
extends Component

class_name GroundMoverComponent

const DEFAULT_GROUND_DOWN_Y: float = 925.0
const DEFAULT_GROUND_UP_Y: float = -25000.0
const LOCKEDFLY_GAMEMODE_GRID_HEIGHTS: Dictionary = {
	Player.Gamemode.CUBE: 10,
	Player.Gamemode.SHIP: 10,
	Player.Gamemode.UFO: 10,
	Player.Gamemode.BALL: 8,
	Player.Gamemode.WAVE: 10,
	Player.Gamemode.ROBOT: 10,
	Player.Gamemode.SPIDER: 9,
	Player.Gamemode.SWING: 10,
}

@export var freefly: bool = true


func _ready() -> void:
	parent.body_entered.connect(_move_grounds)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"freefly": true,
	}
	return DEFAULT_VALUES.get(property)


func _get_configuration_warnings() -> PackedStringArray:
	if not parent.has_node("GamemodeChangerComponent"):
		return ["A sibling GamemodeChangerComponent is required."]
	else:
		return []


func _move_grounds(_player: Player) -> void:
	if LevelManager.player_camera and get_viewport().get_camera_2d() == LevelManager.player_camera:
		LevelManager.player_camera.freefly = freefly
	if freefly:
		return
	GroundData.center = parent.global_position
	GroundData.distance = LOCKEDFLY_GAMEMODE_GRID_HEIGHTS[parent.get_node("GamemodeChangerComponent")._gamemode] * Constants.CELL_SIZE * 0.5
	if parent.global_position.y + GroundData.distance > LevelManager.ground_down.default_y:
		GroundData.offset = (parent.global_position.y + GroundData.distance) - LevelManager.ground_down.default_y
	else:
		GroundData.offset = 0
