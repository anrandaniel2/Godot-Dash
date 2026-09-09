@icon("res://addons/at-icons/node2d/swatches.svg")
class_name GDObject
extends Node2D
## One placed Geometry Dash object.
##
## The scene tree of each object type is generated once by
## [code]tools/build_gd_object_scenes.py[/code] into
## [code]scenes/gd_objects/gd_<id>.tscn[/code]: the object's sprites already laid
## out from the atlas, a [code]Collision[/code] body for the shapes you add, and
## an [code]EditorSelectionCollider[/code] for the editor. [Level] instantiates
## that scene once per placement and calls [method setup] with the placement's
## own transform, colours, groups and z order.
##
## The node layout the rest of the game relies on:
## [codeblock]
## GD<id>                   (this script)
## ├── Base                 main colour channel sprites (+ Glow)
## ├── Detail               secondary colour channel sprites, if any
## ├── Collision            StaticBody2D - edit the scene to add shapes
## └── EditorSelectionCollider
## [/codeblock]
## [code]Base[/code] and [code]Detail[/code] are the names [Level],
## [PlaceHandler] and [BaseDetailHandler] look up to attach colour-channel
## watchers, so they behave like the hand-made scenes' [code]Base[/code] and
## [code]Detail[/code] sprites.

## Geometry Dash layers run B4..T3 as -3..9. The gameplay plane sits at Godot
## z_index 0; layers up to B1 land below it, T1 and up above it.
const Z_LAYER_GAMEPLAY: int = 4
## Spacing between Geometry Dash layers in Godot z_index units. Wide enough to
## carry the fine z order (key 25) inside a layer.
const Z_LAYER_STRIDE: int = 64
## Godot's z_index range.
const Z_INDEX_LIMIT: int = 4096

## Object ID in Geometry Dash. Set by the generated scene.
@export var gd_id: int = 0
## Local-space rectangle covering the artwork at scale 1. Set by the generated
## scene; used for culling and the editor selection box.
@export var bounds: Rect2 = Rect2(-64.0, -64.0, 128.0, 128.0)

## Fine draw order within the z layer (Geometry Dash key 25).
var z_order: int = 0
## Coarse draw layer (Geometry Dash key 24; -3..9).
var z_layer: int = 0
## Whether the object's channels draw additively.
var blending: bool = false
## Whether the object's glow sprite is shown.
var glow: bool = false
## Degrees per second of built-in rotation (key 97), 0 for none.
var spin: float = 0.0
## Geometry Dash's "high detail" flag (key 103): dropped in low detail mode.
var high_detail: bool = false
## The object's own colour and HSV shift, kept for saving.
var tint: Color = Color.WHITE
var hsv_shift: PackedFloat32Array = PackedFloat32Array()
var base_alpha: float = 1.0
var detail_tint: Color = Color.WHITE
var detail_hsv_shift: PackedFloat32Array = PackedFloat32Array()

## Shape names the player's hit detection expects on a body (see the Collision
## node's description in the generated scene).
const COLLISION_NODE: StringName = &"Collision"

var _glow: Sprite2D
var _collision: CollisionObject2D
var _has_collision_shapes: bool = false


func _ready() -> void:
	_glow = get_node_or_null(^"Base/Glow")
	_collision = get_node_or_null(NodePath(COLLISION_NODE))
	if _collision != null:
		_has_collision_shapes = _collision_has_shapes()
		# A body without a single shape assigned costs a physics object per
		# placement for nothing; drop it until the scene gets shapes.
		if not _has_collision_shapes:
			_collision.queue_free()
			_collision = null
	# The selection box is only useful in the editor.
	if not Editor.in_editor:
		var selector: Node = get_node_or_null(^"EditorSelectionCollider")
		if selector != null:
			selector.queue_free()
	_apply_glow()
	_apply_spin()


func _collision_has_shapes() -> bool:
	for child: Node in _collision.get_children():
		if child is CollisionShape2D and child.shape != null:
			return true
		if child is CollisionPolygon2D and not child.polygon.is_empty():
			return true
	return false


## Whether this object type carries collision shapes (added by hand in its
## generated scene).
func has_collision() -> bool:
	return _has_collision_shapes


## Configures this placement from the level-data entry [param data] - the
## dictionary [method GDDecorationLoader.to_data] produces.
func setup(data: Dictionary) -> void:
	transform = data.get("transform", Transform2D.IDENTITY)
	z_order = int(data.get("z_order", 0))
	z_layer = int(data.get("z_layer", 0))
	blending = bool(data.get("blending", false))
	glow = bool(data.get("glow", false))
	spin = float(data.get("spin", 0.0))
	high_detail = bool(data.get("high_detail", false))
	tint = data.get("tint", Color.WHITE)
	hsv_shift = data.get("hsv_shift", PackedFloat32Array())
	base_alpha = float(data.get("base_alpha", 1.0))
	detail_tint = data.get("detail_tint", tint)
	detail_hsv_shift = data.get("detail_hsv_shift", PackedFloat32Array())
	for group: Variant in data.get("groups", []):
		add_to_group(StringName(str(group)))
	apply_draw_order()
	if blending:
		var additive := CanvasItemMaterial.new()
		additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = additive
	# The tint is the object's colour until a colour channel repaints it
	# through the Base/Detail HSV watchers; objects on no channel keep it.
	var base: Node2D = get_node_or_null(^"Base")
	if base != null:
		base.modulate = tint
	var detail: Node2D = get_node_or_null(^"Detail")
	if detail != null:
		detail.modulate = detail_tint
	if is_node_ready():
		_apply_glow()
		_apply_spin()


## Maps the Geometry Dash z layer and order onto a Godot z index.
func apply_draw_order() -> void:
	var fine: int = clampi(z_order, -(Z_LAYER_STRIDE / 2 - 1), Z_LAYER_STRIDE / 2 - 1)
	z_index = clampi(
			(z_layer - Z_LAYER_GAMEPLAY) * Z_LAYER_STRIDE + fine,
			-Z_INDEX_LIMIT, Z_INDEX_LIMIT,
	)


func _apply_glow() -> void:
	if _glow != null:
		_glow.visible = glow
		_glow.z_index = -1


func _apply_spin() -> void:
	set_process(not is_zero_approx(spin) and is_visible_in_tree())


func _notification(what: int) -> void:
	# A culled object need not keep spinning; it picks up again when shown.
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready():
		_apply_spin()


func _process(delta: float) -> void:
	rotation += deg_to_rad(spin * delta)


## Local-space rectangle of the artwork at the object's current scale, for the
## culling manager. Rotation is folded in as the bounding box of the rotated
## rectangle.
func get_world_bounds() -> Rect2:
	return transform * bounds


## Serializes this placement back into the level-data entry format.
##
## Colour channels, HSV shifts and opacity are read back from the Base/Detail
## watchers, so edits made in the editor's colour panel are what gets saved.
func to_data() -> Dictionary:
	var channels: Dictionary = { }
	var saved_shift: PackedFloat32Array = hsv_shift
	var saved_detail_shift: PackedFloat32Array = detail_hsv_shift
	var saved_alpha: float = base_alpha
	var base_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(get_node_or_null(^"Base"))
	if base_watcher != null:
		var channel: String = _channel_of(base_watcher)
		if not channel.is_empty():
			channels["base"] = channel
			saved_shift = _shift_of(base_watcher)
			saved_alpha = base_watcher.alpha
	var detail_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(get_node_or_null(^"Detail"))
	if detail_watcher != null:
		var channel: String = _channel_of(detail_watcher)
		if not channel.is_empty():
			channels["detail"] = channel
			saved_detail_shift = _shift_of(detail_watcher)
	var own_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(self)
	var groups: Array = []
	for group: StringName in get_groups():
		# Godot's internal groups start with an underscore.
		if not str(group).begins_with("_"):
			groups.append(str(group))
	return GDDecorationLoader.to_data(
			gd_id,
			name,
			transform,
			groups,
			channels,
			own_watcher.to_data() if own_watcher != null else { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 },
			z_order,
			z_layer,
			tint,
			blending,
			glow,
			saved_shift,
			saved_alpha,
			spin,
			high_detail,
			detail_tint,
			saved_detail_shift,
	)


## Serializes this placement as a [i]gameplay[/i] level-data entry: the
## counterpart of [method to_data] for placements that live on a generated gd
## scene but take part in gameplay (solid blocks, slopes, spikes, saws). Such
## entries reference the gd scene by path so [Level] instantiates them through
## the gameplay path, keeping them out of decoration batching and low-detail
## culling, and keep their Geometry Dash identity for export.
func to_gameplay_data() -> Dictionary:
	var decoration_data := to_data()
	return {
		"name": decoration_data.name,
		"scene_file_path": "scenes/gd_objects/gd_%d.tscn" % gd_id,
		"gd_object_id": gd_id,
		"transform": decoration_data.transform,
		"groups": decoration_data.groups,
		"color_channels": decoration_data.color_channels,
		"hsv": decoration_data.hsv,
	}


static func _channel_of(watcher: HSVWatcher) -> String:
	for group: StringName in watcher.get_groups():
		if str(group).begins_with(Constants.COLOR_CHANNEL_GROUP_PREFIX):
			return str(group)
	return ""


## The watcher's shift in the importer's five-value form
## (h, s, v, s_additive, v_additive); empty when there is no shift.
static func _shift_of(watcher: HSVWatcher) -> PackedFloat32Array:
	if watcher.hsv_shift.size() < 3:
		return PackedFloat32Array()
	var neutral_s: float = 1.0 if watcher.saturation_multiplies else 0.0
	var neutral_v: float = 1.0 if watcher.value_multiplies else 0.0
	if (
			is_zero_approx(watcher.hsv_shift[0])
			and is_equal_approx(watcher.hsv_shift[1], neutral_s)
			and is_equal_approx(watcher.hsv_shift[2], neutral_v)
	):
		return PackedFloat32Array()
	return PackedFloat32Array([
		watcher.hsv_shift[0],
		watcher.hsv_shift[1],
		watcher.hsv_shift[2],
		0.0 if watcher.saturation_multiplies else 1.0,
		0.0 if watcher.value_multiplies else 1.0,
	])
