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
## its [b]artwork[/b] is swapped: the scene's own textures are cleared and the
## Geometry Dash sprites are added beneath the same nodes, so colour channels,
## enter effects, hide attributes and the sawblade's rotation keep working.
##
## Geometry Dash draws an object as a small tree of sprites (an outline over a
## black fill, a sawblade mirrored from one quarter, a two-tone block), all of
## which [GDObjectFrames] describes. Every sprite is drawn at Geometry Dash's
## own scale: 60 atlas pixels to a cell, its trimmed pixels put back where the
## atlas says they belong. An earlier revision stretched the one base frame to
## the size of the texture it replaced, which turned a 60x6 pixel bar (the
## thick pixel-block outline) into a solid white square.
##
## A swap is skipped whenever the artwork is missing, so an object always
## renders with something rather than vanishing.

## Nodes that carry an object's main silhouette, in the order they're searched.
const BASE_NODE_NAMES: PackedStringArray = ["Base", "Sprite"]
## Nodes that carry the recolourable overlay.
const DETAIL_NODE_NAMES: PackedStringArray = ["Detail"]
## Name of the container the Geometry Dash sprites are added under.
const ART_NODE_NAME: StringName = &"GDArt"
## The scene node that pins a nine-patch block's texture scale while the block
## is resized; Geometry Dash artwork scales with the block instead.
const ABSOLUTE_SIZE_NODE_NAME: StringName = &"NinePatchSprite2DAbsoluteSize"


## Swaps [param object]'s artwork for the Geometry Dash artwork of [param gd_id].
##
## Returns [code]true[/code] when the artwork was replaced.
static func apply(object: Node2D, gd_id: int) -> bool:
	if not Config.use_gd_artwork:
		return false

	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames == null:
		# Normal for orbs, portals and triggers, whose Geometry Dash artwork
		# is deliberately left unmapped; not worth a warning.
		return false

	var sheet: GDSpriteSheet.Sheet = GDDecorationLoader.get_sheet()
	if frames.has_visible_root() and sheet.get_frame(frames.base) == null:
		_warn_once(gd_id, "frame '%s' is missing from the atlases" % frames.base)
		return false

	# The node the main silhouette hangs from. Its colour channel watcher, enter
	# effect and any rotation component keep applying to the new artwork.
	var base_node: Node2D = _find_texture_node(object, BASE_NODE_NAMES)
	if base_node == null:
		_warn_once(gd_id, "%s has no texture node to swap" % object.scene_file_path.get_file())
		return false
	# Only scenes that genuinely have a separate Detail node get one: on a
	# single-sprite scene the detail sprites share the base node.
	var detail_node: Node2D = _find_named_node(object, DETAIL_NODE_NAMES)
	if detail_node == null:
		detail_node = base_node

	var base_art: Node2D = _art_container(base_node)
	var detail_art: Node2D = base_art if detail_node == base_node else _art_container(detail_node)

	# Sprites are added in Geometry Dash's draw order: parts behind the root
	# sprite, the root, then the parts in front. Detail sprites go under the
	# Detail node, which the block scenes draw behind Base - where Geometry
	# Dash puts a block's colour fill too.
	var drawn: int = 0
	var root_drawn: bool = false
	for part: Dictionary in frames.parts:
		if int(part.get("order", 0)) >= 0 and not root_drawn:
			root_drawn = true
			if _add_root(base_art, sheet, frames):
				drawn += 1
		var color_class: String = str(part.get("color", GDObjectFrames.COLOR_BASE))
		var container: Node2D = detail_art if color_class == GDObjectFrames.COLOR_DETAIL else base_art
		if _add_part(container, sheet, part):
			drawn += 1
	if not root_drawn and _add_root(base_art, sheet, frames):
		drawn += 1
	if frames.has_detail():
		# Objects whose sprite tree isn't known keep the naming-convention
		# detail frame, drawn behind the base like a Detail node is.
		var detail_sprite: Sprite2D = _add_sprite(detail_art, sheet, frames.detail, "Detail")
		if detail_sprite != null:
			detail_art.move_child(detail_sprite, 0)
			drawn += 1

	if drawn == 0:
		# Nothing could be drawn, so the scene's own artwork stays.
		base_art.free()
		if detail_art != base_art:
			detail_art.free()
		_warn_once(gd_id, "none of its frames could be drawn")
		return false

	# Only now that the replacement exists is the scene's own art hidden.
	_clear_art(base_node)
	if detail_node != base_node:
		_clear_art(detail_node)
	_drop_absolute_size(object)

	object.set_meta(&"gd_art_swapped", true)
	return true


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


## Every descendant of [param node], depth first.
static func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in node.get_children():
		out.append(child)
		out.append_array(_descendants(child))
	return out


## The container under [param anchor] that holds the Geometry Dash sprites,
## created on first use.
##
## Its children are placed in atlas pixels. The anchor's own scale is divided
## out so that one atlas pixel is always [method GDDecorationLoader.art_scale]
## world units at object scale 1 - whatever size texture the scene used - and
## the object's transform then scales, flips and rotates the art as a whole.
static func _art_container(anchor: Node2D) -> Node2D:
	var container: Node2D = anchor.get_node_or_null(NodePath(ART_NODE_NAME)) as Node2D
	if container == null:
		container = Node2D.new()
		container.name = ART_NODE_NAME
		anchor.add_child(container)
	var art: float = GDDecorationLoader.art_scale()
	container.scale = Vector2(
			art / anchor.scale.x if not is_zero_approx(anchor.scale.x) else art,
			art / anchor.scale.y if not is_zero_approx(anchor.scale.y) else art,
	)
	container.rotation = -anchor.rotation
	# The anchor keeps the enter-effect material; the sprites draw with it.
	container.use_parent_material = true
	# Match the batches: no mipmaps on an atlas.
	container.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	return container


## Adds the object's root sprite, unless it is Geometry Dash's empty frame.
static func _add_root(
		container: Node2D,
		sheet: GDSpriteSheet.Sheet,
		frames: GDObjectFrames.ObjectFrames,
) -> bool:
	if not frames.has_visible_root():
		return false
	var sprite: Sprite2D = _add_sprite(container, sheet, frames.base, "Root")
	if sprite == null:
		return false
	if frames.color == GDObjectFrames.COLOR_BLACK:
		# Sawblades, pits, the "b" block set: black whatever the channel says.
		sprite.modulate = Color.BLACK
	sprite.modulate.a = frames.opacity
	return true


## Adds one part of a multi-sprite object, placed relative to the object's
## centre. See [member GDObjectFrames.ObjectFrames.parts] for the fields.
static func _add_part(container: Node2D, sheet: GDSpriteSheet.Sheet, part: Dictionary) -> bool:
	var sprite: Sprite2D = _add_sprite(container, sheet, str(part.get("frame", "")), "Part")
	if sprite == null:
		return false
	# Geometry Dash units (30 to a cell, y up) to atlas pixels (60 to a cell,
	# y down). Rotations are anticlockwise there, clockwise here.
	var px_per_unit: float = float(GDDecorationLoader.HD_ART_UNITS_PER_GRID_UNIT)
	sprite.position = Vector2(float(part.get("x", 0.0)), -float(part.get("y", 0.0))) * px_per_unit
	sprite.rotation = -deg_to_rad(float(part.get("rot", 0.0)))
	sprite.scale = Vector2(float(part.get("sx", 1.0)), float(part.get("sy", 1.0)))
	# The anchor shifts the sprite by a fraction of its own size, in its own
	# local frame - the same space the trim offset lives in.
	var anchor := Vector2(float(part.get("ax", 0.0)), float(part.get("ay", 0.0)))
	if anchor != Vector2.ZERO:
		sprite.offset += Vector2(-anchor.x, anchor.y) * sprite.texture.get_size()
	var opacity: float = clampf(float(part.get("opacity", 1.0)), 0.0, 1.0)
	if str(part.get("color", GDObjectFrames.COLOR_BASE)) == GDObjectFrames.COLOR_BLACK:
		sprite.modulate = Color.BLACK
	sprite.modulate.a = opacity
	return true


## Creates a sprite for [param frame_name] under [param container], or returns
## [code]null[/code] when the frame is not in the atlases.
static func _add_sprite(
		container: Node2D,
		sheet: GDSpriteSheet.Sheet,
		frame_name: String,
		sprite_name: String,
) -> Sprite2D:
	var frame: GDSpriteSheet.Frame = sheet.get_frame(frame_name)
	if frame == null or frame.texture == null:
		return null
	var sprite := Sprite2D.new()
	sprite.name = "%s%d" % [sprite_name, container.get_child_count()]
	sprite.texture = frame.texture
	sprite.centered = true
	# Put the trimmed pixels back where Geometry Dash draws them.
	sprite.offset = Vector2(frame.offset.x, -frame.offset.y)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.use_parent_material = true
	container.add_child(sprite)
	return sprite


## Stops [param node] drawing the scene's own artwork.
##
## The node itself is kept - scenes reference it by name and by NodePath, and
## it carries the colour channel watcher - so only its texture goes. A shader
## written for the old texture (the sawblade's hollow centre) goes with it.
static func _clear_art(node: Node2D) -> void:
	if node is Sprite2D or node is NinePatchSprite2D:
		node.set("texture", null)
	if node is Sprite2D and node.material is ShaderMaterial:
		node.material = null


## Removes the node that keeps a nine-patch block's texture scale fixed while
## the block is resized. Geometry Dash artwork is one tile that scales with the
## block, and the nine-patch it belonged to no longer draws anything.
static func _drop_absolute_size(object: Node2D) -> void:
	var absolute: Node = object.get_node_or_null(NodePath(ABSOLUTE_SIZE_NODE_NAME))
	if absolute == null:
		return
	# Every caller looks this node up by name and tolerates its absence.
	object.remove_child(absolute)
	absolute.free()
