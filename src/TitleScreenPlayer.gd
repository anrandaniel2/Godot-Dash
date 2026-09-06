class_name TitleScreenPlayer
extends Player

var _last_jump: int = 0
var _last_jump_state: int = false
var _jump_interval: int = 0
var _viewport: Viewport


func _ready() -> void:
	if not Config.enable_title_screen_icons:
		queue_free()
		return
	super()
	_viewport = get_viewport()
	robot_animation_tree.active = true
	_robot_state_machine.start(&"walk")


func _process(_delta: float) -> void:
	_global_position_check()


func _should_process() -> bool:
	return not dead


func _get_jump_state() -> int:
	var jump_state: int
	if not Time.get_ticks_msec() - _last_jump > _jump_interval:
		if internal_gamemode == Gamemode.CUBE and not is_on_floor_only():
			return -1
		elif (internal_gamemode == Gamemode.UFO or internal_gamemode == Gamemode.SWING) and _last_jump_state == 1:
			return -1
		_last_jump_state = _prevent_leave_screen(internal_gamemode, _last_jump_state)
		return _last_jump_state
	_jump_interval = randi_range(75, 200)
	jump_state = -1

	match internal_gamemode:
		Gamemode.CUBE when is_on_floor():
			if randi_range(0, 2) == 0:
				jump_state = 1
		Gamemode.SHIP, Gamemode.WAVE:
			if randi_range(0, 1) == 0:
				jump_state = 1
		Gamemode.ROBOT:
			if is_on_floor():
				if randi_range(0, 3) == 0:
					$RobotTimer.start(randf_range(0.05, 0.25))
			else:
				if randi_range(0, 4) == 0:
					$RobotTimer.stop()
			jump_state = 1 if $RobotTimer.time_left > 0.0 else -1
		Gamemode.UFO:
			if randi_range(0, 1) == 0:
				jump_state = 1
		Gamemode.SWING:
			_jump_interval = randi_range(200, 400)
			if randi_range(0, 1) == 0:
				jump_state = 1
		Gamemode.BALL, Gamemode.SPIDER:
			if randi_range(0, 2) == 0:
				jump_state = 1

	_last_jump = Time.get_ticks_msec()
	jump_state = _prevent_leave_screen(internal_gamemode, jump_state)

	_last_jump_state = jump_state
	return jump_state


func reset_replay() -> void:
	return


func _player_death() -> void:
	if dead:
		return
	dead = true
	speed_multiplier = 0.0
	velocity = Vector2.ZERO
	$Icon.hide()
	$DeathEffect.frame = 0
	$DeathEffect.play()
	$DeathParticles.restart()
	$DashParticles.emitting = false
	%GroundParticles.emitting = false
	$Trail.clear_points()
	clear_debug_trail()
	SFXManager.play_sfx("res://assets/sounds/sfx/game_sfx/DeathSound.mp3")
	await get_tree().create_timer(0.5).timeout
	speed_multiplier = 1.0
	global_position.x = 10000
	dead = false
	$Icon.show()
	_global_position_check()


func _prevent_leave_screen(gamemode: Gamemode, original_jump_state: int = -1) -> int:
	match gamemode:
		Gamemode.WAVE, Gamemode.UFO: # Wave and UFO accelerate instantly so we can be nicer
			if position.y < 128:
				return -1
			if position.y > 816:
				return 1
		Gamemode.SHIP:
			match player_scale:
				PlayerScale.NORMAL:
					if position.y < 256 + velocity.y * velocity.y / Engine.physics_ticks_per_second / 28:
						return -1
					if position.y > 532: # Don't do -^ for this one cuz janky movement
						return 1
				PlayerScale.MINI:
					if position.y < 256 + velocity.y * velocity.y / Engine.physics_ticks_per_second / 28:
						return -1
					if position.y > 512: # miniship accel is kinda slow
						return 1
		Gamemode.SWING:
			match player_scale:
				PlayerScale.NORMAL:
					if position.y < 128 + velocity.y * velocity.y / Engine.physics_ticks_per_second / 28 and gravity_flip == -1:
						return 1
					if position.y > 532 and gravity_flip == 1:
						return 1
				PlayerScale.MINI:
					if position.y < 128 + velocity.y * velocity.y / Engine.physics_ticks_per_second / 28 and gravity_flip == -1:
						return 1
					if position.y > 512 and gravity_flip == 1: # miniswing accel is kinda slow
						return 1
	return original_jump_state


func _global_position_check() -> void:
	if global_position.x > _viewport.get_visible_rect().size.x + 1024:
		reset()
		clear_debug_trail()
		robot_animation_tree.active = true
		_robot_state_machine.start(&"walk")
		global_position.x = -512.0
		global_position.y = randi_range(816, 300)
		var remove_unusable_gamemodes := func(gamemode: Gamemode) -> bool:
			return gamemode not in [Gamemode.BALL, Gamemode.SPIDER, displayed_gamemode]
		displayed_gamemode = Gamemode.values().filter(remove_unusable_gamemodes).pick_random()
		internal_gamemode = displayed_gamemode
		player_scale = randi_range(0, 1) as PlayerScale
		update_player_scale(false)
		gravity_flip = 1


func _on_death_restart() -> void:
	clear_debug_trail()
