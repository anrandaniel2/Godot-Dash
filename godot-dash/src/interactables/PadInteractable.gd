class_name PadInteractable
extends Interactable

func _ready() -> void:
	super()
	body_entered.connect(_add_to_player_queue)


func _add_to_player_queue(body: Node2D) -> void:
	if body is not Player:
		return
	var player: Player = body
	if not player.colliding_pad:
		player.colliding_pad = self
		interacted.emit(player)
