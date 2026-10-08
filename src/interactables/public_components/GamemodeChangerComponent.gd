class_name GamemodeChangerComponent
extends Component

enum GamemodeChange {
	BOTH,
	ONLY_INTERNAL,
	ONLY_DISPLAYED,
}

@export var _gamemode: Player.Gamemode
@export var gamemode_change: GamemodeChange


func _ready() -> void:
	parent.interacted.connect(set_gamemode)


## In dual mode a game-mode portal touched by either icon switches both
## (GD: both icons always share a game mode; NamuWiki dual portal notes).
func set_gamemode(player: Player) -> void:
	var players: Array[Player] = [player]
	if not LevelManager.player_duals.is_empty():
		players = [LevelManager.player]
		players.append_array(LevelManager.player_duals)
	for target: Player in players:
		if is_instance_valid(target):
			_apply_gamemode(target)


func _apply_gamemode(player: Player) -> void:
	match gamemode_change:
		GamemodeChange.BOTH:
			player.internal_gamemode = _gamemode
			player.displayed_gamemode = _gamemode
			if LevelManager.platformer:
				LevelManager.touchscreen_controls.enable_platformer(_gamemode == Player.Gamemode.WAVE)
		GamemodeChange.ONLY_INTERNAL:
			player.internal_gamemode = _gamemode
			if LevelManager.platformer:
				LevelManager.touchscreen_controls.enable_platformer(_gamemode == Player.Gamemode.WAVE)
		GamemodeChange.ONLY_DISPLAYED:
			player.displayed_gamemode = _gamemode
