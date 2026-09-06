class_name MenuLoop
extends AudioStreamPlayer

static var default_menu_loop: AudioStream


func _init() -> void:
	if not default_menu_loop:
		ResourceLoader.load_threaded_request("uid://c4sjh7a6mxgv3")
		default_menu_loop = ResourceLoader.load_threaded_get("uid://c4sjh7a6mxgv3")
	Config.menu_loop_changed.connect(_on_config_menu_loop_changed)
	_on_config_menu_loop_changed(Config.menu_loop)


func _ready() -> void:
	await get_tree().process_frame
	play()


func _on_config_menu_loop_changed(menu_loop: String) -> void:
	var was_playing: bool = playing
	var seek_to: float = get_playback_position() + AudioServer.get_time_since_last_mix()
	if menu_loop.is_empty():
		stream = default_menu_loop
		playing = was_playing
		seek(seek_to)
		return
	AssetManager.load_song_threaded_request(menu_loop)
	stream = AssetManager.load_song_threaded_get(menu_loop)
	playing = was_playing
	seek(seek_to)
	finished.connect(play)
