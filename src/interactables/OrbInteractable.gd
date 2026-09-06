class_name OrbInteractable
extends Interactable
## `interacted` is emitted when the player jumps on the orb.

func _ready() -> void:
	super()
	body_entered.connect(_add_to_player_queue)
	body_exited.connect(_remove_from_player_queue)
	interacted.connect(_remove_from_player_queue)


func _add_to_player_queue(body: Node2D) -> void:
	if body is not Player:
		return
	var player: Player = body
	player.orb_queue.push_front(self)


func _remove_from_player_queue(body: Node2D) -> void:
	if body is not Player:
		return
	var player: Player = body
	player.orb_queue.erase(self)
