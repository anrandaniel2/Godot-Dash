extends Button


func _ready() -> void:
	pressed.connect(_on_pressed)
	refresh()


func refresh() -> void:
	disabled = true
	add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.4))
	modulate = Color.WHITE
	if not Config.check_for_updates:
		text = "v&s" % UpdateManager.version
		return
	if UpdateManager.status == UpdateManager.Status.CHECKING:
		text = "v%s – Checking for updates..." % UpdateManager.version
		await UpdateManager.finished
	disabled = false
	match UpdateManager.status:
		UpdateManager.Status.UP_TO_DATE:
			text = "v%s – Up to date." % UpdateManager.version
		UpdateManager.Status.OUT_OF_DATE:
			text = "v%s – New update available: v%s! Click to download." % [UpdateManager.version, UpdateManager.latest_version]
			add_theme_color_override("font_color", Color.WHITE)
		UpdateManager.Status.NEWER_THAN_UPSTREAM:
			text = "v%s – Current version is more recent than latest release (v%s)." % [UpdateManager.version, UpdateManager.latest_version]
		UpdateManager.Status.FAILED:
			text = "v%s – Could not check for updates." % UpdateManager.version
			add_theme_color_override("font_color", Color.WHITE)
			modulate = Color.DARK_RED


func _on_pressed() -> void:
	if UpdateManager.status == UpdateManager.Status.OUT_OF_DATE:
		OS.shell_open(UpdateManager.latest_release_url)
		text = "Link opened!"
		await get_tree().create_timer(1.0).timeout
		text = "v%s – New update available: v%s! Click to download." % [UpdateManager.version, UpdateManager.latest_version]
		return
	UpdateManager.check_for_updates()
	refresh()
