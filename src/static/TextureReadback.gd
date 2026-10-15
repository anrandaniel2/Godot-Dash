@abstract
class_name TextureReadback

## CPU copies for editor crops/blends. Never replace the GPU-compressed source
## texture; decoding belongs at the image-operation boundary, not in rendering.
static func prepare(image: Image) -> Image:
	if image == null:
		return null
	if image.is_compressed():
		var error: Error = image.decompress()
		if error != OK:
			push_error("Texture readback decompression failed: %s" % error)
			return null
	# Block formats can decode to RGB8 or RGBA8. Blending requires matching formats.
	image.convert(Image.FORMAT_RGBA8)
	return image


static func read(texture: Texture2D) -> Image:
	if texture == null:
		return null
	if texture is AtlasTexture:
		# AtlasTexture.get_image() crops before returning. Decode its parent first,
		# since Image.get_region() cannot operate on GPU-compressed blocks.
		var page: Image = read(texture.atlas)
		if page == null:
			return null
		var region: Rect2i = Rect2i(Rect2(texture.region.position, texture.region.size.floor()))
		if region.size.x == 0:
			region.size.x = texture.atlas.get_width()
		if region.size.y == 0:
			region.size.y = texture.atlas.get_height()
		return page.get_region(region)
	return prepare(texture.get_image())
