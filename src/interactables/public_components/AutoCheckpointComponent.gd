class_name AutoCheckpointComponent
extends Component

func _ready() -> void:
	parent.interacted.connect(place_auto_checkpoint)


func place_auto_checkpoint(player: Player) -> void:
	var player_just_respawned: bool = LevelManager.current_level.stopwatch.elapsed_time < get_process_delta_time()
	if LevelManager.practice_mode and not player_just_respawned:
		player.place_checkpoint().use_auto_sprite().done()
