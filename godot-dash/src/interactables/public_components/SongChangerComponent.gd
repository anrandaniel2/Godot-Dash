class_name SongChangerComponent
extends Component

@export_global_file(
	"*.mp3",
	"*.ogg",
	"*.wav",
	"load_root:user://created_levels/songs/", # Custom data
	"import_to:user://created_levels/songs/", # Custom data
)
var path: String:
	set(value):
		if LevelManager.current_level:
			LevelManager.current_level.register_required_song(path, value.get_file())
		path = value.get_file()
		AssetManager.load_song_threaded_request(Constants.SONG_DIR + value.get_file())
@export_range(0.0, 60.0, 0.01, "or_greater", "suffix:s") var start_offset: float
@export_custom(PROPERTY_HINT_TOOL_BUTTON, "Preview,Play") var preview: Callable = start_preview

var is_previewing: bool


func _ready() -> void:
	# don't make the request twice, the path setter will run at _init
	LevelManager.current_level.register_required_song(path, path)
	parent.interacted.connect(start)


func _validate_property(property: Dictionary) -> void:
	if property.name == "preview" and is_previewing:
		property.hint_string = "Preview,Stop"


func start(_player: Player = null) -> void:
	if path.is_empty():
		return
	LevelManager.song_player.stream = AssetManager.load_song_threaded_get(Constants.SONG_DIR + path)
	LevelManager.song_player.stream.resource_path = Constants.SONG_DIR + path
	LevelManager.song_player.play(start_offset)


func start_preview() -> void:
	if is_previewing or path.is_empty():
		is_previewing = false
		notify_property_list_changed()
		LevelManager.song_player.stop()
		LevelManager.song_player.stream = AssetManager.load_song_threaded_get(Constants.SONG_DIR + LevelManager.current_level.song_path)
		return
	is_previewing = true
	notify_property_list_changed()
	start()
