@icon("res://addons/at-icons/node2d/swatches.svg")
class_name Decoration
extends Node2D
## A Geometry Dash decoration object, drawn from the bundled atlases.
##
## Decoration has no collision and no gameplay behaviour. It reproduces
## Geometry Dash's three-layer object structure:
## [codeblock]
## Base    the main silhouette, tinted by the object's main colour channel
## Detail  the recolourable overlay, tinted by the secondary channel
## Glow    an additive highlight, when the object has one
## [/codeblock]
## The children are deliberately named [code]Base[/code] and [code]Detail[/code]
## because [method PlaceHandler.add_hsv_watchers] and [BaseDetailHandler] look
## up exactly those names when binding an object to a colour channel - so
## decoration inherits the existing colour pipeline with no special cases.

## Geometry Dash object ID, kept so the object survives a save/load round trip
## and so the editor can report what an unfamiliar sprite actually is.
@export_storage var gd_object_id: int = 0


## Builds a decoration node.
##
## [param frames] names the layers; [param sheet] supplies their textures.
## Returns [code]null[/code] if the base layer is unavailable, since an object
## with no silhouette is not worth placing.
static func create(
		gd_id: int,
		frames: GDObjectFrames.ObjectFrames,
		sheet: GDSpriteSheet.Sheet,
) -> Decoration:
	var base_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.base)
	if base_frame == null:
		return null

	var decoration := Decoration.new()
	decoration.gd_object_id = gd_id
	decoration.add_child(_make_layer("Base", base_frame))

	if frames.has_detail():
		var detail_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.detail)
		if detail_frame != null:
			decoration.add_child(_make_layer("Detail", detail_frame))

	if frames.has_glow():
		var glow_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.glow)
		if glow_frame != null:
			var glow: Sprite2D = _make_layer("Glow", glow_frame)
			# Glow layers are drawn additively in Geometry Dash.
			var material := CanvasItemMaterial.new()
			material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			glow.material = material
			glow.z_index = -1
			decoration.add_child(glow)

	var collider: Node = preload(
			"res://scenes/components/level_components/EditorSelectionCollider.tscn"
	).instantiate()
	collider.name = "EditorSelectionCollider"
	collider.type = 8 # INTERACTABLE: a non-solid selection shape
	decoration.add_child(collider)

	return decoration


## Creates one sprite layer, compensating for the atlas packer's trimming.
static func _make_layer(layer_name: String, frame: GDSpriteSheet.Frame) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = layer_name
	sprite.texture = frame.texture
	# LINEAR, not LINEAR_WITH_MIPMAPS: the atlases carry no mip chain, and mips of
	# a packed page blend neighbouring frames into each other.
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# The packer crops transparent borders, which shifts the remaining pixels
	# off-centre. spriteOffset puts them back. Cocos2d's Y axis points up and
	# Godot's points down, hence the negation.
	sprite.position = Vector2(frame.offset.x, -frame.offset.y)
	return sprite
