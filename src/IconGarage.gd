class_name IconGarage
extends VBoxContainer

@export var preview_icons: HBoxContainer
@export var icon_selector: GridContainer
@export var title_screen_player: TitleScreenPlayer

var tab: PreviewIcon.Icon = PreviewIcon.Icon.CUBE
var thread: Thread
var update_queued: bool = false
var updating: bool = false


func _ready() -> void:
	thread = Thread.new()
	%Primary.set_value_no_signal(Config.primary_color)
	%Secondary.set_value_no_signal(Config.secondary_color)
	%Glow.set_value_no_signal(Config.glow_color)
	%Outline.set_value_no_signal(Config.outline_color)
	%"Hue Shift Speed".set_value_no_signal(Config.icon_hue_shift_speed)
	%Primary.default = Config.primary_color
	%Secondary.default = Config.secondary_color
	%Glow.default = Config.glow_color
	%Outline.default = Config.outline_color
	%"Hue Shift Speed".default = Config.icon_hue_shift_speed
	refresh()


func _exit_tree() -> void:
	if thread.is_started():
		thread.wait_to_finish()


func reload() -> void:
	AssetManager.cache_icon_paths()
	refresh()


func refresh() -> void:
	var loaded_preview_icon: PackedScene = load("res://scenes/components/game_components/PreviewIcon.tscn")
	NodeUtils.free_children(icon_selector)
	var icon_type: PreviewIcon.Icon = tab
	for icon_path: String in AssetManager.icon_paths[icon_type]:
		var button := TextureButton.new()
		var preview_icon: PreviewIcon = loaded_preview_icon.instantiate()
		preview_icon.type = icon_type
		preview_icon.path = icon_path
		button.z_index = 4096
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(96, 96)
		button.set_script(BouncyButton)
		button.texture_normal = preview_icon.get_icon_texture()
		if icon_type == PreviewIcon.Icon.TRAIL:
			button.flip_h = true
			button.material = preload("res://resources/AdditiveBlendingMaterial.tres")
		elif icon_type != PreviewIcon.Icon.DEATH_EFFECT:
			button.material = preload("res://resources/Icon.tres")
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.ignore_texture_size = true
		icon_selector.add_child.call_deferred(button)
		button.pressed.connect(_on_icon_pressed.bind(preview_icon))
	update_icons()


func update_icons() -> void:
	preview_icons.get_node(^"Cube").path = Config.icon_paths[PreviewIcon.Icon.CUBE]
	preview_icons.get_node(^"Ship/Ship").path = Config.icon_paths[PreviewIcon.Icon.SHIP]
	preview_icons.get_node(^"Ship/Jetpack").path = Config.icon_paths[PreviewIcon.Icon.JETPACK]
	preview_icons.get_node(^"UFO").path = Config.icon_paths[PreviewIcon.Icon.UFO]
	preview_icons.get_node(^"Ball").path = Config.icon_paths[PreviewIcon.Icon.BALL]
	preview_icons.get_node(^"Wave").path = Config.icon_paths[PreviewIcon.Icon.WAVE]
	preview_icons.get_node(^"Robot").path = Config.icon_paths[PreviewIcon.Icon.ROBOT]
	preview_icons.get_node(^"Spider").path = Config.icon_paths[PreviewIcon.Icon.SPIDER]
	preview_icons.get_node(^"Swing").path = Config.icon_paths[PreviewIcon.Icon.SWING]
	# preview_icons.get_node(^"DeathEffect").path = Config.icon_paths[PreviewIcon.Icon.DEATH_EFFECT]
	title_screen_player.refresh_textures()


func colors_updated() -> void:
	update_queued = true
	while update_queued and not updating:
		updating = true
		update_queued = false
		if thread.is_started():
			thread.wait_to_finish()
		thread.start(AssetManager.cache_icons.bind(PreviewIcon.Icon.values(), false))
		await AssetManager.icons_loaded
		refresh()
		updating = false


func _on_icon_pressed(icon: PreviewIcon) -> void:
	Config.icon_paths[icon.type] = icon.path
	match icon.type:
		PreviewIcon.Icon.SHIP:
			preview_icons.get_node(^"Ship/Ship").show()
			preview_icons.get_node(^"Ship/Jetpack").hide()
		PreviewIcon.Icon.JETPACK:
			preview_icons.get_node(^"Ship/Ship").hide()
			preview_icons.get_node(^"Ship/Jetpack").show()
	Config.save()
	update_icons()


func _on_tab_changed(value: int) -> void:
	# Manual conversion is needed so Player.Gamemode can still be converted into PreviewIcon.Icon
	match value:
		0:
			tab = PreviewIcon.Icon.CUBE
		1:
			tab = PreviewIcon.Icon.SHIP
		2:
			tab = PreviewIcon.Icon.JETPACK
		3:
			tab = PreviewIcon.Icon.UFO
		4:
			tab = PreviewIcon.Icon.BALL
		5:
			tab = PreviewIcon.Icon.WAVE
		6:
			tab = PreviewIcon.Icon.ROBOT
		7:
			tab = PreviewIcon.Icon.SPIDER
		8:
			tab = PreviewIcon.Icon.SWING
		9:
			tab = PreviewIcon.Icon.TRAIL
		10:
			tab = PreviewIcon.Icon.DEATH_EFFECT
	refresh()


func _on_ship_pressed() -> void:
	var ship_sprite: CanvasItem = preview_icons.get_node(^"Ship/Ship")
	var jetpack_sprite: CanvasItem = preview_icons.get_node(^"Ship/Jetpack")
	ship_sprite.visible = not ship_sprite.visible
	jetpack_sprite.visible = not jetpack_sprite.visible


func _on_primary_value_changed(color: Color) -> void:
	Config.primary_color = color
	colors_updated()


func _on_secondary_value_changed(color: Color) -> void:
	Config.secondary_color = color
	colors_updated()


func _on_glow_value_changed(color: Color) -> void:
	Config.glow_color = color
	colors_updated()


func _on_outline_value_changed(color: Color) -> void:
	Config.outline_color = color
	colors_updated()


func _on_hue_shift_speed_value_changed(value: float) -> void:
	RenderingServer.global_shader_parameter_set(&"icon_hue_shift_speed", value)
	Config.icon_hue_shift_speed = value
	Config.save()


func _on_color_changer_interaction_ended(_color: Color, _previous: Color) -> void:
	# HACK: Trying to join the thread here causes an infinite freeze.
	var one_frame: Signal = get_tree().process_frame
	if thread.is_alive():
		await one_frame
	thread.start(AssetManager.cache_icons)
	await AssetManager.icons_loaded
	update_icons()
