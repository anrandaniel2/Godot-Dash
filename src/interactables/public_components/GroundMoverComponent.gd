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
## Imported Geometry Dash portals: the exact band GD writes
## (animateInDualGroundNew), as Godot Y of the floor and ceiling lines. Used
## instead of the portal-centred grid height when [member use_gd_band] is set.
@export var use_gd_band: bool = false
@export var gd_band_floor_y: float = 0.0
@export var gd_band_ceiling_y: float = 0.0
## Imported GD portals: the band height in GD units. When set, the band is
## worked out from where the portal is when touched, so a portal moved by
## triggers frames the camera at its new place, as in GD (the touched
## object's position feeds the band, gdsolver bands.hpp).
@export var gd_band_height: float = 0.0


## Global Y of a level-space band line.
static func gd_band_global_y(level_y: float) -> float:
	var level: Level = LevelManager.current_level
	return level.to_global(Vector2(0.0, level_y)).y if level != null and level.is_inside_tree() else level_y


func _ready() -> void:
	parent.body_entered.connect(_move_grounds)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"freefly": true,
		"use_gd_band": false,
		"gd_band_floor_y": 0.0,
		"gd_band_ceiling_y": 0.0,
		"gd_band_height": 0.0,
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
		LevelManager.player_camera.portal_freefly = freefly
	if freefly:
		return
	if use_gd_band:
		# The band is in level coordinates; GroundObject places the grounds
		# from GroundData in global ones (the level sits at y = 925).
		var floor_level_y: float = gd_band_floor_y
		var ceiling_level_y: float = gd_band_ceiling_y
		var level: Level = LevelManager.current_level
		if gd_band_height > 0.0 and level != null and level.is_inside_tree():
			var portal_level_y: float = level.to_local(parent.global_position).y
			var portal_gd_y: float = (GMDConverter.GROUND_Y - portal_level_y) / Constants.CELL_SIZE * GMDConverter.GD_CELL_SIZE
			var band: Vector2 = GMDConverter.gd_portal_band(portal_gd_y, gd_band_height)
			floor_level_y = GMDConverter.gd_to_godot_y(band.x)
			ceiling_level_y = GMDConverter.gd_to_godot_y(band.y)
		var floor_y: float = gd_band_global_y(floor_level_y)
		var ceiling_y: float = gd_band_global_y(ceiling_level_y)
		GroundData.center = Vector2(parent.global_position.x, (floor_y + ceiling_y) * 0.5)
		GroundData.distance = absf(floor_y - ceiling_y) * 0.5
		GroundData.offset = 0
		return
	GroundData.center = parent.global_position
	GroundData.distance = LOCKEDFLY_GAMEMODE_GRID_HEIGHTS[parent.get_node("GamemodeChangerComponent")._gamemode] * Constants.CELL_SIZE * 0.5
	if parent.global_position.y + GroundData.distance > LevelManager.ground_down.default_y:
		GroundData.offset = (parent.global_position.y + GroundData.distance) - LevelManager.ground_down.default_y
	else:
		GroundData.offset = 0
