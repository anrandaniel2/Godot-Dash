class_name RenderMode
extends PanelContainer

@export_group("Panels")
@export var enum_button: EnumButton
@export var fold_button: Button
@export var options_panel: PanelContainer
@export var options_panel_vbox: VBoxContainer
@export var global_segment: VBoxContainer
@export var object_segment: VBoxContainer

@export_group("Global")

@export_group("Object")
@export var background_color_selector: ColorProperty
@export var ground_color_selector: ColorProperty
@export var line_color_selector: ColorProperty
@export var object_color_selector: ColorProperty

@export_group("Material")

@export_group("Rendered")

var mode: Mode = Mode.RENDERED_MODE
var object_modulate: Color = Color.WHITE

enum Mode {
	OBJECT_MODE,
	MATERIAL_MODE,
	RENDERED_MODE,
	TEMP,
}


func _ready() -> void:
	await get_tree().process_frame
	toggle_render_mode_options(false)
	Editor.render_mode_manager = self
	enum_button.value_changed.connect(
		func(enum_variant: int):
			update(enum_variant)
	)
	background_color_selector.set_value_no_signal(Color.GRAY)
	background_color_selector.value_changed.connect(
		func(value: Color):
			if mode == Mode.OBJECT_MODE:
				mode = Mode.TEMP
				Editor.root.level.background_color = value
				mode = Mode.OBJECT_MODE
	)
	ground_color_selector.set_value_no_signal(Color.GRAY)
	ground_color_selector.value_changed.connect(
		func(value: Color):
			if mode == Mode.OBJECT_MODE:
				mode = Mode.TEMP
				Editor.root.level.ground_color = value
				mode = Mode.OBJECT_MODE
	)
	line_color_selector.set_value_no_signal(Color.WHITE)
	line_color_selector.value_changed.connect(
		func(value: Color):
			if mode == Mode.OBJECT_MODE:
				mode = Mode.TEMP
				Editor.root.level.line_color = value
				mode = Mode.OBJECT_MODE
	)
	object_color_selector.set_value_no_signal(object_modulate)
	object_color_selector.value_changed.connect(
		func(value: Color):
			if mode == Mode.OBJECT_MODE:
				object_modulate = value
				LevelManager.update_hsv_watchers.emit()
	)

	mode = Config.default_render_mode
	enum_button.set_value_no_signal(mode)


func update(_mode: Mode = mode) -> void:
	if _mode == mode:
		return
	match _mode:
		Mode.OBJECT_MODE:
			enable_object_mode()
		Mode.MATERIAL_MODE:
			enable_material_mode()
		Mode.RENDERED_MODE:
			enable_rendered_mode()
	if fold_button.button_pressed:
		var minimum_size: float = options_panel.custom_minimum_size.y
		toggle_render_mode_options(false, false)
		toggle_render_mode_options(true, false)
		var new_minimum_size: float = options_panel.custom_minimum_size.y
		options_panel.custom_minimum_size.y = minimum_size
		var tween := create_tween()
		tween.tween_property(options_panel, "custom_minimum_size:y", new_minimum_size, 0.25).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)


func enable_object_mode() -> void:
	LevelManager.game_scene.get_node(^"ShaderLayer").visible = false
	var level: Level = Editor.root.level
	level.ground_color = ground_color_selector.get_value()
	level.background_color = background_color_selector.get_value()
	level.line_color = line_color_selector.get_value()
	mode = Mode.OBJECT_MODE # Locks editing of level colors
	toggle_enter_effect(false)
	LevelManager.update_hsv_watchers.emit()


func enable_material_mode() -> void:
	mode = Mode.MATERIAL_MODE
	LevelManager.game_scene.get_node(^"ShaderLayer").visible = false
	var level: Level = Editor.root.level
	level.ground_color = level.default_ground_color
	level.background_color = level.default_background_color
	level.line_color = level.default_line_color
	toggle_enter_effect(false)
	LevelManager.update_hsv_watchers.emit()


func enable_rendered_mode() -> void:
	mode = Mode.RENDERED_MODE
	LevelManager.game_scene.get_node(^"ShaderLayer").visible = true
	var level: Level = Editor.root.level
	level.ground_color = level.default_ground_color
	level.background_color = level.default_background_color
	level.line_color = level.default_line_color
	toggle_enter_effect(true)
	LevelManager.update_hsv_watchers.emit()


func toggle_enter_effect(value: bool):
	AssetManager.fade_enter_effect.set_shader_parameter(&"enabled", value)
	AssetManager.fade_enter_effect_canvas_group.set_shader_parameter(&"enabled", value)


func toggle_render_mode_options(value: bool, animate: bool = true, time: float = 0.25) -> void:
	if value:
		$VBoxContainer.add_theme_constant_override("separation", 4)
		options_panel.show()
		match mode:
			Mode.OBJECT_MODE:
				object_segment.show()
		global_segment.show()
		var minimum_size: float = 52

		for child in options_panel_vbox.get_children():
			if child.visible:
				minimum_size += 36 * child.get_child_count() + 4

		if animate:
			var tween := create_tween()
			tween.set_parallel(true)
			tween.tween_property(fold_button.get_node(^"TextureRect"), ^"rotation_degrees", -90.0, time).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
			tween.tween_property(options_panel, ^"custom_minimum_size:y", minimum_size, time).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
			options_panel.get_node(^"MarginContainer").show()
			for child in options_panel_vbox.get_children():
				for property in child.get_children():
					property.hide()
			while options_panel.custom_minimum_size.y != minimum_size:
				await get_tree().process_frame
				var count: int = round((options_panel.custom_minimum_size.y - 56) / 36)
				for child in options_panel_vbox.get_children():
					if child.visible == true:
						for property in child.get_children():
							if count <= 0:
								break
							property.show()
							count -= 1
		else:
			options_panel.custom_minimum_size.y = minimum_size
			fold_button.get_node(^"TextureRect").rotation_degrees = -90
			options_panel.get_node(^"MarginContainer").show()
			for child in options_panel_vbox.get_children():
				if child.visible == true:
					for property in child.get_children():
						property.show()
	else:
		for child in options_panel_vbox.get_children():
			if child is VBoxContainer:
				child.hide()
		options_panel.get_node(^"MarginContainer").hide()
		$VBoxContainer.add_theme_constant_override("separation", 0)
		if animate:
			var tween := create_tween()
			tween.set_parallel(true)
			tween.tween_property(fold_button.get_node(^"TextureRect"), "rotation_degrees", -180.0, time).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
			tween.tween_property(options_panel, "custom_minimum_size:y", 0, time).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
			await tween.finished
		else:
			options_panel.custom_minimum_size.y = 0
			fold_button.get_node(^"TextureRect").rotation_degrees = -180.0
		options_panel.hide()
