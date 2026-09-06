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


func set_gamemode(player: Player) -> void:
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
