@abstract
class_name GMDObjects
## Mapping between Geometry Dash object IDs and Godot Dash scenes.
##
## Geometry Dash has thousands of object IDs, the vast majority of which are
## decoration that Godot Dash has no equivalent for. Only the IDs listed in
## [member MAP] are imported; [b]every other ID is skipped[/b] (see
## [method GMDConverter.import_level_string]), so importing a level built with
## objects this project doesn't have simply drops those objects instead of
## erroring out.
##
## Each entry describes one importable object:
## [codeblock]
## {
##     "scene": "scenes/.../YellowOrb.tscn", # path relative to res://
##     "name": "YellowOrb",                  # node name given to the instance
##     "colorable": false,                   # has Base/Detail nodes
##     "components": [...],                  # public components it owns
##     "type": EditorSelectionCollider.Type, # selection collider type
##     "id": 0,                              # texture variant id, optional
## }
## [/codeblock]

const SOLIDS := "scenes/components/level_components/solids/"
const HAZARDS := "scenes/components/level_components/hazards/"
const ORBS := "scenes/components/level_components/orbs/"
const PADS := "scenes/components/level_components/pads/"
const GAMEMODE_PORTALS := "scenes/components/level_components/portals/gamemode_portals/"
const OTHER_PORTALS := "scenes/components/level_components/portals/other_portals/"
const SPEED_PORTALS := "scenes/components/level_components/portals/speed_portals/"
const TRIGGERS := "scenes/components/level_components/triggers/"
const LEVEL_COMPONENTS := "scenes/components/level_components/"
## Directory of the generated Geometry Dash object scenes (relative paths).
const GD_OBJECT_SCENES := "scenes/gd_objects/"

## Geometry Dash object ID -> Godot Dash object description.
const MAP: Dictionary[int, Dictionary] = {
	#region Solids
	# The basic square block and the handful of full-square variants Godot Dash
	# can represent with its nine patch block.
	1: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	2: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	3: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	4: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	5: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	6: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	7: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	467: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	468: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	469: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	470: { "scene": SOLIDS + "NinePatchBlock.tscn", "name": "Block", "colorable": true },
	1202: { "scene": SOLIDS + "PixelBlock.tscn", "name": "PixelBlock", "colorable": true },
	1203: { "scene": SOLIDS + "PixelBlock.tscn", "name": "PixelBlock", "colorable": true },
	1204: { "scene": SOLIDS + "PixelBlock.tscn", "name": "PixelBlock", "colorable": true },
	1205: { "scene": SOLIDS + "PixelBlock.tscn", "name": "PixelBlock", "colorable": true },
	#endregion

	#region Slopes
	289: { "scene": SOLIDS + "DefaultSlopeNormal.tscn", "name": "Slope", "colorable": true },
	290: { "scene": SOLIDS + "DefaultSlopeNormal.tscn", "name": "Slope", "colorable": true },
	291: { "scene": SOLIDS + "DefaultSlopeLarge.tscn", "name": "SlopeLarge", "colorable": true },
	292: { "scene": SOLIDS + "DefaultSlopeLarge.tscn", "name": "SlopeLarge", "colorable": true },
	#endregion

	#region Hazards
	8: { "scene": HAZARDS + "Spike.tscn", "name": "Spike" },
	39: { "scene": HAZARDS + "SpikeFlat.tscn", "name": "SpikeFlat" },
	103: { "scene": HAZARDS + "SpikeMedium.tscn", "name": "SpikeMedium" },
	392: { "scene": HAZARDS + "SpikeSmall.tscn", "name": "SpikeSmall" },
	216: { "scene": HAZARDS + "GroundSpike.tscn", "name": "GroundSpike" },
	217: { "scene": HAZARDS + "GroundSpike.tscn", "name": "GroundSpike" },
	88: { "scene": HAZARDS + "Sawblade.tscn", "name": "Sawblade" },
	89: { "scene": HAZARDS + "SawbladeMedium.tscn", "name": "SawbladeMedium" },
	98: { "scene": HAZARDS + "SawbladeSmall.tscn", "name": "SawbladeSmall" },
	397: { "scene": HAZARDS + "Sawblade.tscn", "name": "Sawblade" },
	398: { "scene": HAZARDS + "SawbladeMedium.tscn", "name": "SawbladeMedium" },
	399: { "scene": HAZARDS + "SawbladeSmall.tscn", "name": "SawbladeSmall" },
	675: { "scene": HAZARDS + "Sawblade.tscn", "name": "Sawblade" },
	676: { "scene": HAZARDS + "SawbladeMedium.tscn", "name": "SawbladeMedium" },
	677: { "scene": HAZARDS + "SawbladeSmall.tscn", "name": "SawbladeSmall" },
	#endregion

	#region Orbs
	36: { "scene": ORBS + "YellowOrb.tscn", "name": "YellowOrb" },
	84: { "scene": ORBS + "BlueOrb.tscn", "name": "BlueOrb" },
	141: { "scene": ORBS + "PinkOrb.tscn", "name": "PinkOrb" },
	1022: { "scene": ORBS + "GreenOrb.tscn", "name": "GreenOrb" },
	1330: { "scene": ORBS + "BlackOrb.tscn", "name": "BlackOrb" },
	1333: { "scene": ORBS + "DashOrbGreen.tscn", "name": "DashOrbGreen" },
	1704: { "scene": ORBS + "RedOrb.tscn", "name": "RedOrb" },
	1751: { "scene": ORBS + "DashOrbMagenta.tscn", "name": "DashOrbMagenta" },
	3004: { "scene": ORBS + "SpiderOrb.tscn", "name": "SpiderOrb" },
	3027: { "scene": ORBS + "TeleportOrb.tscn", "name": "TeleportOrb" },
	# The toggle orb's ToggleComponent stores an array of ToggledGroup
	# resources, which has no direct Geometry Dash equivalent, so it is
	# imported with its scene defaults and left for the creator to configure.
	1594: { "scene": ORBS + "ToggleOrb.tscn", "name": "ToggleOrb" },
	#endregion

	#region Pads
	35: { "scene": PADS + "YellowPad.tscn", "name": "YellowPad" },
	67: { "scene": PADS + "BluePad.tscn", "name": "BluePad" },
	140: { "scene": PADS + "PinkPad.tscn", "name": "PinkPad" },
	1332: { "scene": PADS + "RedPad.tscn", "name": "RedPad" },
	1932: { "scene": PADS + "BlackPad.tscn", "name": "BlackPad" },
	3005: { "scene": PADS + "SpiderPad.tscn", "name": "SpiderPad" },
	#endregion

	#region Gamemode portals
	12: { "scene": GAMEMODE_PORTALS + "CubePortal.tscn", "name": "CubePortal" },
	13: { "scene": GAMEMODE_PORTALS + "ShipPortal.tscn", "name": "ShipPortal" },
	47: { "scene": GAMEMODE_PORTALS + "BallPortal.tscn", "name": "BallPortal" },
	111: { "scene": GAMEMODE_PORTALS + "UFOPortal.tscn", "name": "UFOPortal" },
	660: { "scene": GAMEMODE_PORTALS + "WavePortal.tscn", "name": "WavePortal" },
	745: { "scene": GAMEMODE_PORTALS + "RobotPortal.tscn", "name": "RobotPortal" },
	1331: { "scene": GAMEMODE_PORTALS + "SpiderPortal.tscn", "name": "SpiderPortal" },
	1933: { "scene": GAMEMODE_PORTALS + "SwingPortal.tscn", "name": "SwingPortal" },
	#endregion

	#region Other portals
	10: { "scene": OTHER_PORTALS + "GravityPortalFlipped.tscn", "name": "GravityPortalFlipped" },
	11: { "scene": OTHER_PORTALS + "GravityPortalNormal.tscn", "name": "GravityPortalNormal" },
	2926: { "scene": OTHER_PORTALS + "GravityPortalToggle.tscn", "name": "GravityPortalToggle" },
	99: { "scene": OTHER_PORTALS + "ScalePortalNormal.tscn", "name": "ScalePortalNormal" },
	101: { "scene": OTHER_PORTALS + "ScalePortalSmall.tscn", "name": "ScalePortalSmall" },
	286: { "scene": OTHER_PORTALS + "CountPortalDual.tscn", "name": "CountPortalDual" },
	287: { "scene": OTHER_PORTALS + "CountPortalSingle.tscn", "name": "CountPortalSingle" },
	747: { "scene": OTHER_PORTALS + "TeleportalIn.tscn", "name": "TeleportalIn" },
	#endregion

	#region Speed portals
	200: { "scene": SPEED_PORTALS + "SpeedPortal05x.tscn", "name": "SpeedPortal05x" },
	201: { "scene": SPEED_PORTALS + "SpeedPortal1x.tscn", "name": "SpeedPortal1x" },
	202: { "scene": SPEED_PORTALS + "SpeedPortal2x.tscn", "name": "SpeedPortal2x" },
	203: { "scene": SPEED_PORTALS + "SpeedPortal3x.tscn", "name": "SpeedPortal3x" },
	1334: { "scene": SPEED_PORTALS + "SpeedPortal4x.tscn", "name": "SpeedPortal4x" },
	#endregion

	#region Triggers
	899: {
		"scene": TRIGGERS + "ColorTrigger.tscn",
		"name": "ColorTrigger",
		"components": ["TargetColorChannelComponent", "ColorChannelChangerComponent", "EasingComponent"],
	},
	901: {
		"scene": TRIGGERS + "MoveTrigger.tscn",
		"name": "MoveTrigger",
		"components": ["TargetGroupComponent", "PositionChangerComponent", "EasingComponent"],
	},
	1007: {
		"scene": TRIGGERS + "AlphaTrigger.tscn",
		"name": "AlphaTrigger",
		"components": ["TargetGroupComponent", "AlphaChangerComponent", "EasingComponent"],
	},
	1049: {
		"scene": TRIGGERS + "ToggleTrigger.tscn",
		"name": "ToggleTrigger",
		"components": ["ToggleComponent"],
	},
	# SpawnTriggerComponent holds SpawnedTrigger resources rather than a plain
	# target group, so it keeps its defaults too.
	1268: { "scene": TRIGGERS + "SpawnTrigger.tscn", "name": "SpawnTrigger" },
	1346: {
		"scene": TRIGGERS + "RotateTrigger.tscn",
		"name": "RotateTrigger",
		"components": ["TargetGroupComponent", "RotationChangerComponent", "EasingComponent"],
	},
	2067: {
		"scene": TRIGGERS + "ScaleTrigger.tscn",
		"name": "ScaleTrigger",
		"components": ["TargetGroupComponent", "ScaleChangerComponent", "EasingComponent"],
	},
	1520: {
		"scene": TRIGGERS + "CameraShakeTrigger.tscn",
		"name": "CameraShakeTrigger",
		"components": ["CameraShakeComponent", "EasingComponent"],
	},
	1913: {
		"scene": TRIGGERS + "CameraZoomTrigger.tscn",
		"name": "CameraZoomTrigger",
		"components": ["CameraZoomChangerComponent", "EasingComponent"],
	},
	1914: {
		"scene": TRIGGERS + "CameraStaticTrigger.tscn",
		"name": "CameraStaticTrigger",
		"components": ["TargetObjectComponent", "CameraStaticComponent", "EasingComponent"],
	},
	1916: {
		"scene": TRIGGERS + "CameraOffsetTrigger.tscn",
		"name": "CameraOffsetTrigger",
		"components": ["CameraOffsetChangerComponent", "EasingComponent"],
	},
	2015: {
		"scene": TRIGGERS + "CameraRotateTrigger.tscn",
		"name": "CameraRotateTrigger",
		"components": ["CameraRotationChangerComponent", "EasingComponent"],
	},
	2062: {
		"scene": TRIGGERS + "CameraEdgeTrigger.tscn",
		"name": "CameraEdgeTrigger",
		"components": ["TargetObjectComponent"],
	},
	1934: {
		"scene": TRIGGERS + "SongTrigger.tscn",
		"name": "SongTrigger",
		"components": ["SongChangerComponent", "EasingComponent"],
	},
	1935: {
		"scene": TRIGGERS + "TimewarpTrigger.tscn",
		"name": "TimewarpTrigger",
		"components": ["TimescaleChangerComponent", "EasingComponent"],
	},
	2066: {
		"scene": TRIGGERS + "GravityTrigger.tscn",
		"name": "GravityTrigger",
		"components": ["GravityMultiplierChangerComponent", "EasingComponent"],
	},
	2900: {
		"scene": TRIGGERS + "GameplayRotateTrigger.tscn",
		"name": "GameplayRotateTrigger",
		"components": ["GameplayRotationChangerComponent", "EasingComponent"],
	},
	2901: {
		"scene": TRIGGERS + "CameraGameplayOffsetTrigger.tscn",
		"name": "CameraGameplayOffsetTrigger",
		"components": ["CameraGameplayOffsetChangerComponent", "EasingComponent"],
	},
	3022: {
		"scene": TRIGGERS + "TeleportTrigger.tscn",
		"name": "TeleportTrigger",
		"components": ["TeleportComponent"],
	},
	3600: { "scene": TRIGGERS + "EndLevelTrigger.tscn", "name": "EndLevelTrigger" },
	#endregion

	#region Misc
	914: { "scene": LEVEL_COMPONENTS + "Text.tscn", "name": "Text", "components": ["TextComponent"] },
	#endregion
}

## Complete Geometry Dash 2.2 effect-trigger object ID inventory. Families that
## do not yet have a dedicated Godot component scene use one inert trigger shell
## and are still retained by the packed native scheduler instead of being
## silently discarded as decoration.
const TRIGGER_IDS: Array[int] = [
	34, 899, 901, 1006, 1007, 1049, 1268, 1346, 1347, 1520, 1585, 1595,
	1611, 1612, 1613, 1616, 1811, 1812, 1814, 1815, 1817, 1818, 1819,
	1912, 1913, 1914, 1915, 1916, 1917, 1931, 1932, 1934, 1935, 2015,
	2062, 2066, 2067, 2068, 2899, 2900, 2901, 2903, 2904, 2905, 2907,
	2909, 2910, 2911, 2912, 2913, 2914, 2915, 2916, 2917, 2919, 2920,
	2921, 2922, 2923, 2924, 2925, 2999, 3006, 3007, 3008, 3009, 3010,
	3011, 3012, 3013, 3014, 3015, 3016, 3017, 3018, 3019, 3020, 3021,
	3022, 3023, 3024, 3029, 3030, 3031, 3033, 3600, 3602, 3603, 3604,
	3605, 3606, 3607, 3608, 3609, 3612, 3613, 3614, 3615, 3617, 3618,
	3619, 3620, 3641, 3642, 3655, 3660, 3661, 3662,
]
const GENERIC_TRIGGER: Dictionary = {
	"scene": TRIGGERS + "NativeGenericTrigger.tscn",
	"name": "NativeTrigger",
}


## Geometry Dash object ID ranges that are [i]solid square blocks[/i].
##
## Any ID inside one of these ranges that isn't in [member MAP] is imported as a
## plain [code]NinePatchBlock[/code] instead of being skipped, so a level built
## out of block styles Godot Dash doesn't have still has walkable geometry.
##
## [b]This is deliberately an allowlist, not a catch-all.[/b] Geometry Dash's ID
## space is mostly decoration - spikes, pulsing glow, chains, text, particles -
## and turning those into solid blocks would fill the level with invisible
## walls that break gameplay far worse than a missing sprite. Only ranges known
## to be full-square collidable blocks are listed here.
##
## Ranges are inclusive on both ends and were taken from the standard block tabs
## in the Geometry Dash editor, then checked one ID at a time against the
## bundled atlases. IDs with no artwork at all (189, 262, 276, 293, 318-320,
## 330, 332, 334-336, 344, 346-348, 350, 352, 379, 380, 387-389, 717, 718,
## 743, 1211-1213) and IDs that turned out to be decoration or hazards
## (thorns, clouds, bars, blades, rotating balls, spike art...) were removed:
## with no frame to swap in, each of those rendered as the scene's plain white
## placeholder texture - a random solid white block in the middle of a level.
const BLOCK_ID_RANGES: Array[Vector2i] = [
	Vector2i(1, 7),       # default square blocks
	Vector2i(40, 40),     # 1.0 plank
	Vector2i(83, 83),     # brick block
	Vector2i(90, 91),     # alternate squares
	Vector2i(96, 96),     # alternate square
	Vector2i(116, 122),   # 1.6 block set
	Vector2i(146, 147),   # invisible block / plank
	Vector2i(160, 165),   # 1.7 block set
	Vector2i(170, 174),   # 1.7 block set
	Vector2i(192, 194),   # 1.8 block set
	Vector2i(245, 245),   # brick block
	Vector2i(259, 261),   # 1.9 block set
	Vector2i(263, 266),   # 1.9 block set
	Vector2i(273, 275),   # 1.9 block set
	Vector2i(277, 282),   # 1.9 block set
	Vector2i(294, 296),   # 1.9 block set
	Vector2i(317, 317),   # 2.0 block set
	Vector2i(321, 321),   # 2.0 block set
	Vector2i(325, 329),   # 2.0 block set
	Vector2i(331, 331),   # 2.0 block set
	Vector2i(333, 333),   # 2.0 block set
	Vector2i(337, 337),   # 2.0 block set
	Vector2i(343, 343),   # 2.0 block set
	Vector2i(345, 345),   # 2.0 block set
	Vector2i(349, 349),   # 2.0 block set
	Vector2i(351, 351),   # 2.0 block set
	Vector2i(369, 370),   # 2.0 planks
	Vector2i(373, 374),   # 2.0 plank squares
	Vector2i(467, 470),   # 2.0 default blocks
	Vector2i(474, 481),   # 2.0 block set
	Vector2i(492, 493),   # 2.0 block set
	Vector2i(586, 593),   # 2.1 block set
	Vector2i(639, 640),   # 2.1 block set
	Vector2i(662, 664),   # 2.1 block set
	Vector2i(688, 692),   # 2.1 block set
	Vector2i(719, 721),   # 2.1 block set
	Vector2i(766, 766),   # 2.1 block set
	Vector2i(768, 769),   # 2.1 block set
	Vector2i(1202, 1205), # pixel blocks
	Vector2i(1220, 1222), # pixel blocks
]

## The scene an unrecognised block ID falls back to.
const FALLBACK_BLOCK: Dictionary = {
	"scene": SOLIDS + "NinePatchBlock.tscn",
	"name": "Block",
	"colorable": true,
}


## [code]true[/code] when [param gd_id] is a solid square block that Godot Dash
## has no specific scene for, and so should be imported as a plain block.
static func is_fallback_block(gd_id: int) -> bool:
	if MAP.has(gd_id):
		return false
	for range_: Vector2i in BLOCK_ID_RANGES:
		if gd_id >= range_.x and gd_id <= range_.y:
			# Only stand in for a block whose real artwork can be drawn over
			# the placeholder scene; otherwise the level gets a white square.
			return GDObjectFrames.has_frames(gd_id)
	return false


## Reverse lookup built lazily on first export.
static var _export_map: Dictionary[String, int]


## Returns the description for a Geometry Dash object ID, or an empty
## [Dictionary] when Godot Dash has no equivalent object.
##
## Unrecognised [i]solid block[/i] IDs resolve to [member FALLBACK_BLOCK] rather
## than nothing, so unsupported block styles still import as plain blocks.
static func get_object(gd_id: int) -> Dictionary:
	if MAP.has(gd_id):
		return MAP[gd_id]
	if gd_id in TRIGGER_IDS:
		return GENERIC_TRIGGER
	if is_fallback_block(gd_id):
		return FALLBACK_BLOCK
	return { }


## [code]true[/code] when the object ID can be imported, either because it has a
## dedicated scene or because it's a block that falls back to a plain one.
static func is_supported(gd_id: int) -> bool:
	return MAP.has(gd_id) or gd_id in TRIGGER_IDS or is_fallback_block(gd_id)


## The generated scene for [param gd_id] as a relative path
## ([code]scenes/gd_objects/gd_<id>.tscn[/code]), or an empty [String] when the
## build has no such scene (run tools/build_gd_object_scenes.py).
static func gd_scene_path(gd_id: int) -> String:
	var path := GD_OBJECT_SCENES + "gd_%d.tscn" % gd_id
	return path if ResourceLoader.exists("res://" + path) else ""


## [code]true[/code] when [param gd_id] is a [i]static[/i] gameplay object - a
## solid block, a slope, a spike or a saw - as opposed to an interactive object
## (orb, pad, portal, trigger) or a decoration.
##
## Static objects only exist to be walked on or to kill the player: their scene
## contributes solid/hazard collision and nothing else, so they can be built
## from their generated gd scene (atlas art + authored collision) instead of a
## hand-made component scene.
static func is_static_gameplay_object(gd_id: int) -> bool:
	var description := get_object(gd_id)
	if description.is_empty():
		return false
	var scene: String = description.get("scene", "")
	return scene.begins_with(SOLIDS) or scene.begins_with(HAZARDS)


## Returns the Geometry Dash object ID for a Godot Dash scene path
## (with or without the [code]res://[/code] prefix), or [code]-1[/code] when
## that object has no Geometry Dash counterpart.
static func get_gd_id(scene_file_path: String) -> int:
	if _export_map.is_empty():
		for gd_id: int in MAP:
			var scene: String = MAP[gd_id].scene
			# Several GD IDs collapse onto one scene; keep the lowest (most
			# canonical) ID so exports round-trip to the plain variant.
			if not _export_map.has(scene) or _export_map[scene] > gd_id:
				_export_map[scene] = gd_id
	return _export_map.get(scene_file_path.trim_prefix("res://"), -1)
