extends Node

var players: Array[AudioStreamPlayer] = []


func play_sfx(sfx_path: String) -> void:
	var sfx_player := AudioStreamPlayer.new()
	players.append(sfx_player)
	add_child(sfx_player)
	sfx_player.stream = load(sfx_path)
	sfx_player.play()
	await sfx_player.finished
	sfx_player.queue_free()
	players.erase(sfx_player)


func cancel_all_sfx() -> void:
	for player: AudioStreamPlayer in players:
		player.queue_free()
	players.clear()
