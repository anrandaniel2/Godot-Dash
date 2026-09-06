@tool
extends Node

@export var button_group: ButtonGroup
@export var type: EditorSelectionCollider.Type
@export var object: PackedScene
@export var textures: Array[TextureOverride]

@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate Buttons") var _generate_buttons = generate_buttons

@onready var parent := get_parent()


func generate_buttons() -> void:
	var clear_children := func(child): if child is BouncyButton:child.queue_free()
	parent.get_children().map(clear_children)
	for i in range(len(textures)):
		var texture_override := textures[i]
		texture_override.name = texture_override.base.resource_path.get_file().get_basename().trim_suffix("Base")
		# Button
		var button := BouncyButton.new()
		button.block_palette_button = true
		button.custom_minimum_size = Vector2.ONE * 64.0
		button.set_meta("texture_override", texture_override)
		button.set_meta("_edit_group_", true)
		button.name = texture_override.name
		button.toggle_mode = true
		button.button_group = button_group
		parent.add_child(button, true)
		button.owner = parent.owner
		# Ref
		var block_palette_ref := BlockPaletteRef.new()
		block_palette_ref.type = type
		block_palette_ref.id = i
		block_palette_ref.object = object
		button.add_child(block_palette_ref)
		block_palette_ref.owner = parent.owner
		block_palette_ref.name = "BlockPaletteRef"
		# Display
		var center_container := CenterContainer.new()
		center_container.size = button.size
		button.add_child(center_container)
		center_container.owner = parent.owner

		var texture_rects: Array[TextureRect]

		var base := TextureRect.new()
		base.texture = texture_override.base
		base.name = "Base"
		base.texture_filter = texture_override.filtering

		if texture_override.detail != null:
			var detail := TextureRect.new()
			detail.texture = texture_override.detail
			detail.name = "Detail"
			detail.texture_filter = texture_override.filtering
			texture_rects.append(detail)
			if texture_override.base_detail_same_color:
				detail.modulate.v = 0.75

		texture_rects.append(base)

		for texture_rect in texture_rects:
			texture_rect.expand_mode = TextureRect.ExpandMode.EXPAND_IGNORE_SIZE
			texture_rect.custom_minimum_size = button.size
			texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			center_container.add_child(texture_rect)
			texture_rect.owner = parent.owner
