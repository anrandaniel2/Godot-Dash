extends Node

const TOAST_PACKED := preload("res://scenes/components/game_components/Toast.tscn")
const TOAST_LAYER_PACKED := preload("res://scenes/components/game_components/ToastLayer.tscn")

enum {
	NONE = 0,
	PERSISTENT = 1, # Doesn't disappear after a delay, the user must click on it to dismiss it.
	PAUSABLE = 1 << 1,
}

var toast_layer: CanvasLayer
var toast_container: VBoxContainer

## Keys of warnings already shown once, so a repeated problem - one trigger
## firing on every attempt, say - doesn't spam the screen with the same toast.
var _warned_once: Dictionary = { }


func new_toast(text: String, duration: float = 2.0, options: int = NONE) -> Toast:
	if not get_tree().root.has_node("ToastLayer"):
		toast_layer = TOAST_LAYER_PACKED.instantiate() as CanvasLayer
		get_tree().root.add_child.call_deferred(toast_layer, true)
	else:
		toast_layer = get_tree().root.get_node("ToastLayer") as CanvasLayer
	toast_container = toast_layer.get_node(^"ToastContainer")
	var toast := TOAST_PACKED.instantiate() as Toast
	toast.text = text
	toast.lifetime = duration
	toast.persistent = options & PERSISTENT
	toast.pausable = options & PAUSABLE
	toast_container.add_child(toast)
	return toast


func error(text: String, duration: float = 2.0, options: int = NONE) -> Toast:
	var toast = new_toast(text, duration, options)
	toast.modulate = Color.DEEP_PINK
	return toast


func warning(text: String, duration: float = 2.0, options: int = NONE) -> Toast:
	var toast = new_toast(text, duration, options)
	toast.modulate = Color.YELLOW
	return toast


func warning_once(key: String, text: String, duration: float = 2.0, options: int = NONE) -> Toast:
	if _warned_once.has(key):
		return null
	_warned_once[key] = true
	return warning(text, duration, options)
