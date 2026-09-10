extends Node
## Exercises the real title-screen Community tree. This catches invalid exported
## node references and setup-time script failures that a resource import alone
## does not make fatal.


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://scenes/TitleScreen.tscn") as PackedScene
	if packed == null:
		_fail("TitleScreen.tscn did not load")
		return
	var title := packed.instantiate()
	add_child(title)
	await get_tree().process_frame
	await get_tree().process_frame

	var path := "TitleScreenLayer/TitleScreen/Community/MarginContainer/VBoxContainer/SmoothScrollContainer/LevelPanelLoader"
	var loader := title.get_node_or_null(path)
	if loader == null:
		_fail("LevelPanelLoader is missing")
		return
	var required_properties := [
		"online_client",
		"online_search",
		"local_mode_button",
		"online_mode_button",
		"online_category",
		"previous_page_button",
		"page_status",
		"next_page_button",
		"search_timer",
	]
	for property: String in required_properties:
		if loader.get(property) == null:
			_fail("Community export resolved to null: " + property)
			return

	# Verify the scene-authored signal changes mode. Do not wait for the external
	# server: this test validates UI wiring deterministically.
	var online_button := loader.get("online_mode_button") as Button
	online_button.pressed.emit()
	await get_tree().process_frame
	var category := loader.get("online_category") as OptionButton
	if not loader.get("online_mode") or not category.visible:
		_fail("ONLINE LEVELS did not activate the online browser")
		return
	print("COMMUNITY_UI_SMOKE: PASS")
	title.queue_free()
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("COMMUNITY_UI_SMOKE: " + message)
	get_tree().quit(1)
