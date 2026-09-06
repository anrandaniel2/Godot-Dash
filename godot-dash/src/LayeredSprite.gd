class_name LayeredSprite
extends Node2D

func get_composite_image() -> Image:
	var child_images: Array[Image]
	var child_rects: Array[Rect2i]
	var child_position_deltas: Array[Vector2i]
	for child: Node2D in get_children():
		var image: Image = child.texture.get_image()
		var image_rect: Rect2i = Rect2i(Vector2i.ZERO, image.get_size())
		var position_delta: Vector2i = Vector2i(child.position - position)
		child_images.append(image)
		child_rects.append(image_rect)
		child_position_deltas.append(position_delta)
	# Create an image with a size corresponding to
	# the maximum bounding box of the sprites, avoiding cutoff.
	var max_rect: Rect2i
	for i: int in child_rects.size():
		var image_rect: Rect2i = child_rects[i]
		var positionned_rect: Rect2i = image_rect
		positionned_rect.position += child_position_deltas[i] - Vector2i(image_rect.size / 2.0)
		max_rect = max_rect.merge(positionned_rect)

	var composite_image: Image = Image.create_empty(max_rect.size.x, max_rect.size.y, false, Image.FORMAT_RGBA8)
	for i: int in child_images.size():
		var image: Image = child_images[i]
		var image_rect: Rect2i = child_rects[i]
		var position_delta: Vector2i = child_position_deltas[i] + Vector2i((max_rect.size - image_rect.size) / 2.0)
		composite_image.blend_rect(image, image_rect, position_delta)
	return composite_image
