@abstract
class_name GDArtSwap
## Replaces a gameplay object's built-in artwork with Geometry Dash's own.
##
## Godot Dash ships original art for the objects it models - blocks, spikes,
## orbs, pads, portals. That art is deliberately unlike Geometry Dash's, so an
## imported level ends up half authentic (decoration, drawn from the atlases)
## and half Godot Dash (everything that has a scene). Side by side with the real
## game the difference is stark: crisp white outlined blocks and plain white
## triangles where Geometry Dash has its own shading.
##
## Those objects still need their scene - it carries the collision shape, the
## editor collider and any gameplay components - so the node is kept and only
## its [b]textures[/b] are swapped for the matching atlas frames.
##
## 69 of the ids Godot Dash models have real artwork in the bundled atlases.
##
## A swap is skipped whenever the frame is missing, so an object always renders
## with something rather than vanishing.

## Nodes that carry an object's main silhouette, in the order they're searched.
const BASE_NODE_NAMES: PackedStringArray = ["Base", "Sprite"]
## Nodes that carry the recolourable overlay.
const DETAIL_NODE_NAMES: PackedStringArray = ["Detail"]


## Swaps [param object]'s textures for the Geometry Dash artwork of [param gd_id].
##
## Returns [code]true[/code] when at least one texture was replaced.
static func apply(object: Node2D, gd_id: int) -> bool:
	if not Config.use_gd_artwork:
		return false

	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames == null:
		# Normal for orbs, portals and triggers, whose Geometry Dash artwork
		# is deliberately left unmapped; not worth a warning.
		return false

	var sheet: GDSpriteSheet.Sheet = GDDecorationLoader.get_sheet()
	var base_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.base)
	if base_frame == null:
		_warn_once(gd_id, "frame '%s' is missing from the atlases" % frames.base)
		return false

	var swapped: bool = false

	# The base silhouette. Its original texture size is remembered so a
	# detail node that ships without a texture can be sized to match it.
	var base_node: Node2D = _find_texture_node(object, BASE_NODE_NAMES)
	var reference_size: Vector2 = Vector2.ZERO
	if base_node != null:
		var original: Variant = base_node.get("texture")
		if original is Texture2D:
			reference_size = original.get_size()
		if _set_texture(base_node, base_frame, object):
			swapped = true

	# The recolourable overlay. Only scenes that genuinely have a separate
	# Detail node get one: on a single-sprite scene such as GroundSpike the
	# fallback search would hand back the node just written to, and the detail
	# frame would overwrite the base artwork.
	var detail_node: Node2D = _find_named_node(object, DETAIL_NODE_NAMES)
	if detail_node != null:
		if frames.has_detail():
			# The block scenes ship their Detail node empty, so the swap has
			# to work without a previous texture: the detail layer is where
			# a two-tone block's colour fill lives, and dropping it left just
			# a hollow outline.
			var detail_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.detail)
			if detail_frame != null and _set_texture(detail_node, detail_frame, object, reference_size):
				swapped = true
		elif detail_node.get("texture") != null:
			# Geometry Dash draws nothing here, so Godot Dash's own detail art
			# is hidden rather than left showing through.
			detail_node.visible = false

	if not swapped:
		_warn_once(gd_id, "%s has no texture node to swap" % object.scene_file_path.get_file())
	return swapped


## Objects whose swap failed, reported once each. A failed swap leaves the
## scene's placeholder art showing - for blocks that is a plain white square,
## so the reason must not be swallowed.
static var _warned: Dictionary[int, bool] = { }


static func _warn_once(gd_id: int, reason: String) -> void:
	if _warned.has(gd_id):
		return
	_warned[gd_id] = true
	push_warning("GDArtSwap: object %d keeps its placeholder art, %s" % [gd_id, reason])


## Finds a child by exact name, without the recursive fallback.
##
## Used for the detail layer, where guessing is harmful: picking an arbitrary
## sprite would overwrite the base artwork on single-sprite scenes.
static func _find_named_node(object: Node2D, names: PackedStringArray) -> Node2D:
	for node_name: String in names:
		var node: Node2D = object.get_node_or_null(NodePath(node_name)) as Node2D
		if node != null:
			return node
	return null


## Finds the node holding an object's main texture.
static func _find_texture_node(object: Node2D, names: PackedStringArray) -> Node2D:
	var named: Node2D = _find_named_node(object, names)
	if named != null:
		return named

	# Fall back to a recursive search, which covers scenes using a bespoke
	# sprite name ("RegularSpike01") and portals, whose sprites are nested a
	# level down under "Sprites". The largest sprite wins, because portals stack
	# a back plate, a front frame and a small indicator icon and it is the main
	# plate that should carry the Geometry Dash artwork.
	var best: Sprite2D = null
	var best_area: float = 0.0
	for child: Node in _descendants(object):
		if child is Sprite2D and child.texture != null:
			var size: Vector2 = child.texture.get_size() * child.scale.abs()
			var area: float = size.x * size.y
			if area > best_area:
				best_area = area
				best = child
	return best


## Swaps a nine-patch node for a plain sprite showing the frame whole.
##
## The node itself is kept - scenes reference it by name and by NodePath - so
## its texture is cleared and a child Sprite2D is added in its place. That keeps
## the scene tree valid while getting the artwork drawn 1:1.
static func _replace_nine_patch(node: Node2D, frame: GDSpriteSheet.Frame, object: Node2D) -> bool:
	var target_size: Vector2 = node.get("size")
	if target_size.x <= 0.0 or target_size.y <= 0.0:
		target_size = Vector2(Constants.CELL_SIZE, Constants.CELL_SIZE)

	# Stop the nine-patch drawing anything.
	node.set("texture", null)

	var sprite: Sprite2D = node.get_node_or_null(^"GDArt") as Sprite2D
	if sprite == null:
		sprite = Sprite2D.new()
		sprite.name = "GDArt"
		node.add_child(sprite)

	sprite.texture = frame.texture
	# Match the batches: no mipmaps on an atlas.
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.centered = bool(node.get("centered")) if node.get("centered") != null else true
	# Scale the frame to exactly cover the space the block occupies.
	var frame_size: Vector2 = frame.texture.get_size()
	if frame_size.x > 0.0 and frame_size.y > 0.0:
		sprite.scale = Vector2(target_size.x / frame_size.x, target_size.y / frame_size.y)
	sprite.position = Vector2(frame.offset.x, -frame.offset.y) * sprite.scale

	object.set_meta(&"gd_art_swapped", true)
	return true


## Every descendant of [param node], depth first.
static func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in node.get_children():
		out.append(child)
		out.append_array(_descendants(child))
	return out


## Assigns an atlas frame to a texture-bearing node, scaling it so the artwork
## occupies the space the original texture did.
##
## [param reference_size] stands in for the original texture size when the
## node has no texture of its own (the empty Detail node of a block scene).
static func _set_texture(
		node: Node2D,
		frame: GDSpriteSheet.Frame,
		object: Node2D,
		reference_size: Vector2 = Vector2.ZERO,
) -> bool:
	# Only Sprite2D and NinePatchSprite2D carry textures the swap understands.
	if not (node is Sprite2D or node is NinePatchSprite2D):
		return false

	# The size the artwork has to cover: the node's own texture, or the base
	# layer's when the node ships empty. A nine-patch sizes itself.
	var previous: Variant = node.get("texture")
	var previous_size: Vector2 = reference_size
	if previous is Texture2D:
		previous_size = (previous as Texture2D).get_size()
	if node is Sprite2D and (previous_size.x <= 0.0 or previous_size.y <= 0.0):
		return false

	node.set("texture", frame.texture)
	if node.get("texture_filter") != null:
		node.set("texture_filter", CanvasItem.TEXTURE_FILTER_LINEAR)

	var new_size: Vector2 = frame.texture.get_size()
	if new_size.x <= 0.0 or new_size.y <= 0.0:
		return false

	# Geometry Dash block art is a single tile meant to be drawn whole, not
	# nine-sliced. Godot Dash's own blocks are 512px textures with 36px margins
	# designed for stretching; Geometry Dash's are 60px tiles, several of which
	# (blockOutline_01, for one) are a hollow 2px frame around empty space.
	# Nine-slicing those smears the border across the whole block and fills the
	# middle with stretched nothing - the blurry white slabs.
	#
	# So a nine-patch node is converted to a plain sprite for the swap: the
	# frame is drawn once, at the size the block occupies.
	if node is NinePatchSprite2D:
		return _replace_nine_patch(node, frame, object)

	# Plain sprites are rescaled so the frame covers what the old texture did.
	var previous_scale: Vector2 = node.scale
	node.scale = Vector2(
			previous_scale.x * previous_size.x / new_size.x,
			previous_scale.y * previous_size.y / new_size.y,
	)
	# Put the trimmed pixels back where Geometry Dash draws them.
	node.position += Vector2(frame.offset.x, -frame.offset.y) * node.scale

	object.set_meta(&"gd_art_swapped", true)
	return true
