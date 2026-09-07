@abstract
class_name ObjectThumbnail

## Decoded atlas pages, so a thousand Geometry Dash object icons don't each
## pull the whole page back from the GPU.
static var _page_images: Dictionary[Texture2D, Image] = { }


## The image of one atlas region, via the page cache.
static func _atlas_image(texture: AtlasTexture) -> Image:
	if texture == null or texture.atlas == null:
		return null
	if not _page_images.has(texture.atlas):
		var page: Image = texture.atlas.get_image()
		if page == null:
			return null
		_page_images[texture.atlas] = page
	var region: Rect2i = Rect2i(texture.region)
	if region.size.x <= 0 or region.size.y <= 0:
		return null
	return _page_images[texture.atlas].get_region(region)


## The root sprite of a placed Geometry Dash object - enough for an icon; the
## fills and mirrored quarters of a multi-sprite object would only blur it.
static func _gd_object_images(object: GDObject) -> Array[Image]:
	var images: Array[Image]
	for layer_name: String in ["Base", "Detail"]:
		var layer: Node = object.get_node_or_null(NodePath(layer_name))
		if layer == null:
			continue
		var root: Node = layer.get_node_or_null(^"Root")
		var candidates: Array[Node] = [root] if root != null else layer.get_children()
		for sprite: Node in candidates:
			if sprite is Sprite2D and sprite.texture is AtlasTexture and sprite.name != &"Glow":
				var image: Image = _atlas_image(sprite.texture)
				if image != null:
					images.append(image)
					return images
	return images


static func get_object_thumbnail_image(object: CanvasItem) -> Array[Image]:
	const REBOUND_ORB_TEXTURE: Texture2D = preload("res://assets/textures/guis/editor/block_palette/ReboundOrbPreview.svg")
	const REBOUND_PAD_TEXTURE: Texture2D = preload("res://assets/textures/guis/editor/block_palette/ReboundPadPreview.svg")
	const TEXT_TEXTURE: Texture2D = preload("res://assets/textures/Text.svg")
	var images: Array[Image]
	if object is GDObject:
		return _gd_object_images(object)
	for child: Node in object.get_children():
		if child is TriggerSprite:
			images.append(crop_image_around_center(child.texture.get_image(), 0.5))
		elif child is Label:
			images.append(crop_image_around_center(TEXT_TEXTURE.get_image(), 0.7))
		elif child is ReboundOrbSprite:
			images.append(REBOUND_ORB_TEXTURE.get_image())
		elif child is ReboundPadSprite:
			images.append(REBOUND_PAD_TEXTURE.get_image())
		elif child is LayeredSprite:
			images.append(child.get_composite_image())
		elif child is Sprite2D or child is NinePatchSprite2D:
			if child.texture:
				images.append(child.texture.get_image())
			else:
				# Geometry Dash artwork swapped onto the sprite (see GDArtSwap)
				# sits in a container beneath it; its own texture was cleared.
				images.append_array(_swapped_art_images(child))
		elif child is CanvasGroup or child is Polygon2D or child is Control:
			images.append_array(get_object_thumbnail_image(child))
	return images


## The images of the Geometry Dash sprites swapped onto [param node], if any.
##
## The root sprite alone is enough for an icon; a multi-sprite object's fills
## and mirrored quarters would only blur a 16 px thumbnail.
static func _swapped_art_images(node: Node) -> Array[Image]:
	var images: Array[Image]
	var art: Node = node.get_node_or_null(NodePath(GDArtSwap.ART_NODE_NAME))
	if art == null:
		return images
	for sprite: Node in art.get_children():
		if sprite is Sprite2D and sprite.texture:
			images.append(sprite.texture.get_image())
			break
	return images


static func crop_image_around_center(image: Image, size_factor: float) -> Image:
	# Shift image to prepare for crop
	var shift_factor: float = (1 - size_factor) / 2.0
	var rect: Rect2i = Rect2i(Vector2i.ZERO, image.get_size())
	image.blit_rect(image, rect, -image.get_size() * shift_factor)
	image.crop(roundi(image.get_width() * size_factor), roundi(image.get_height() * size_factor))
	return image


static func fit_size_to_square(size: Vector2i, side_length: int) -> Vector2i:
	var new_size: Vector2i = Vector2i.ONE * side_length
	if size.x < size.y: # Fit height
		new_size.x = roundi(float(size.x * side_length) / float(size.y))
	else: # Fit width
		new_size.y = roundi(float(size.y * side_length) / float(size.x))
	return new_size


## Generate a square thumbnail of the object.
static func generate(object: Node2D, side_length: int) -> ImageTexture:
	var cache_path: String = "%s_%spx" % [object.scene_file_path, side_length]
	if object.has_meta(Constants.TEXTURE_OVERRIDE_META):
		var texture_override_id: int = object.get_meta(Constants.TEXTURE_OVERRIDE_META).id
		cache_path = "%s_%s" % [texture_override_id, cache_path]
	if cache_path in AssetManager.generated_editor_object_thumbnails:
		return AssetManager.generated_editor_object_thumbnails[cache_path]
	var composite_image_size: Vector2i = Vector2i.ONE * side_length
	var images: Array[Image] = get_object_thumbnail_image(object)
	# An object with nothing drawable (a decoration placeholder, a scene whose
	# artwork could not be resolved) gets a blank icon rather than an error.
	if images.is_empty():
		images.append(Image.create_empty(side_length, side_length, false, Image.FORMAT_RGBA8))
	for image: Image in images:
		var image_size: Vector2i = fit_size_to_square(image.get_size(), side_length)
		image.resize(image_size.x, image_size.y, Image.Interpolation.INTERPOLATE_LANCZOS)
	var composite_image: Image = Image.create_empty(side_length, side_length, false, images[0].get_format())
	for image: Image in images:
		var image_rect: Rect2i = Rect2i(Vector2i.ZERO, image.get_size())
		composite_image.blend_rect(image, image_rect, (composite_image_size - image.get_size()) / 2.0)
	var texture: ImageTexture = ImageTexture.create_from_image(composite_image)
	AssetManager.generated_editor_object_thumbnails[cache_path] = texture
	return texture
