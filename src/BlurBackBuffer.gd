class_name BlurBackBuffer
extends BackBufferCopy

## Fresh screen copy for one blurred panel.
##
## Godot copies the screen once per canvas layer, at the first item that reads
## hint_screen_texture, and every later reader reuses that copy. A panel drawn
## after other UI would then blur a screen without that UI and cover it with
## its opaque fill - the "things disappear behind the blur" bug. One of these
## sits right before each blurred panel and refreshes the copy.
##
## It copies the whole viewport. A RECT copy is given in canvas units, but the
## back buffer is in window pixels: with the canvas_items stretch mode a
## fullscreen (or any resized) window has more pixels than canvas units, so the
## rect covered only part of the panel and the rest sampled stale or black
## texels - the black spots that appeared after a resolution change. RECT mode
## is also known to sample a scaled-down screen on some renderers
## (godotengine/godot#84987). The full copy has no edge, so the blur's mip
## taps never reach unfilled texels either.

const _MATERIAL_PATH := "res://resources/SimpleBlurMaterial.tres"

var _panel: CanvasItem


static func attach_if_blurred(node: Node) -> void:
	if not node is Control or node is BlurBackBuffer:
		return
	var control := node as Control
	if control.material == null or control.material.resource_path != _MATERIAL_PATH:
		return
	if control.get_parent() == null:
		return
	var copy := BlurBackBuffer.new()
	copy._panel = control
	copy.name = "%sBlurCopy" % control.name
	control.get_parent().add_child.call_deferred(copy)
	copy.ready.connect(copy._move_before_panel, CONNECT_ONE_SHOT)


func _ready() -> void:
	copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	z_as_relative = true
	_panel.tree_exiting.connect(queue_free)


func _move_before_panel() -> void:
	if is_instance_valid(_panel) and _panel.get_parent() == get_parent():
		get_parent().move_child(self, _panel.get_index())
		z_index = _panel.z_index


func _process(_delta: float) -> void:
	if not is_instance_valid(_panel):
		return
	var shown := _panel.is_visible_in_tree() and Config.menu_blur
	visible = shown
