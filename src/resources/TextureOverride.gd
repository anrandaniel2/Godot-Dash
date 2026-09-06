@tool
class_name TextureOverride
extends Resource

enum TextureKind {
	VECTOR,
	PIXEL_ART,
}

@export var base: Texture2D
@export var detail: Texture2D
@export var base_detail_same_color: bool
@export var kind: TextureKind:
	set(value):
		kind = value
		filtering = CanvasItem.TEXTURE_FILTER_PARENT_NODE if kind == TextureKind.VECTOR else CanvasItem.TEXTURE_FILTER_NEAREST
@export var prefab_override: PackedScene
@export var scale_factor: Vector2 = Vector2.ONE

@export_storage var name: String
@export_storage var filtering: CanvasItem.TextureFilter
