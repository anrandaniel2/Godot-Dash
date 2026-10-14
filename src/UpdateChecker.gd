extends Button


func _ready() -> void:
	pressed.connect(_on_pressed)
	refresh()


func refresh() -> void:
	# This bottom-left control identifies the installed build in every state.
	# Update status is secondary, never a replacement for the version.
	text = UpdateManager.display_version()
	tooltip_text = ""
	disabled = true
	add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.4))
	modulate = Color.WHITE
	if not Config.check_for_updates:
		return
	if UpdateManager.status == UpdateManager.Status.CHECKING:
		tooltip_text = "Checking for updates…"
		await UpdateManager.finished
	disabled = false
	match UpdateManager.status:
		UpdateManager.Status.UP_TO_DATE, UpdateManager.Status.NEWER_THAN_UPSTREAM:
			tooltip_text = "No newer release available. Click to check again."
		UpdateManager.Status.OUT_OF_DATE:
			text += " · Update available"
			tooltip_text = "Download the installer (keeps your saves)." if UpdateManager.uses_windows_channel() else "Click to download the latest release."
			add_theme_color_override("font_color", Color.WHITE)
		UpdateManager.Status.DISABLED:
			if OS.has_feature("web"):
				tooltip_text = "Updates are handled by the web host."
				disabled = true
			elif OS.has_feature("windows") and not UpdateManager.uses_windows_channel():
				tooltip_text = "Run the Windows installer to update; your saves are kept."
				disabled = true
			else:
				tooltip_text = "Click to check for updates."
		UpdateManager.Status.FAILED:
			tooltip_text = "Could not check for updates. Click to retry."


func _on_pressed() -> void:
	if UpdateManager.status == UpdateManager.Status.DISABLED and (
		OS.has_feature("web") or (OS.has_feature("windows") and not UpdateManager.uses_windows_channel())
	):
		return
	if UpdateManager.status == UpdateManager.Status.OUT_OF_DATE:
		OS.shell_open(UpdateManager.latest_release_url)
		tooltip_text = "Download link opened."
		return
	UpdateManager.check_for_updates()
	refresh()
