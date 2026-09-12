class_name MusicScale
extends Node

## Horizontal distance (world px) beyond which the music pulse stops updating.
## The scale is a purely visual beat and converges by lerp the moment tracking
## resumes, and this is beyond the visible half-width at every zoom the camera
## uses, so a frozen value is never on screen.
const TRACK_RANGE: float = 3500.0

## How many MusicScale components currently exist. Level consults this before
## querying the audio spectrum: without it, every level paid the FFT range
## query every frame even when nothing reads the value.
static var active_count: int = 0

@onready var parent: Node2D = get_parent()
@onready var initial_scale: Vector2 = parent.scale

var disabled: bool


func _ready() -> void:
	process_thread_group = Node.PROCESS_THREAD_GROUP_SUB_THREAD
	active_count += 1


func _exit_tree() -> void:
	active_count = max(0, active_count - 1)


func _process(delta: float):
	if disabled:
		return
	var level: Level = LevelManager.current_level
	if level == null:
		return
	var player: Player = LevelManager.player
	if player != null and absf(parent.global_position.x - player.global_position.x) > TRACK_RANGE:
		return
	parent.set_deferred(
		&"scale",
		parent.scale.lerp(initial_scale * level.music_scale, 1 - exp(-delta * 12)),
	)
