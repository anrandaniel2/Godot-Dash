extends Node
## Discord Rich Presence required the native Discord Game SDK through the `discord-rpc-gd`
## GDExtension, which is not part of this GDScript-only project. Rich Presence is therefore
## unavailable: [member available] is always [code]false[/code], which makes every call site
## guarded by it a no-op.

var available: bool = false


func _ready() -> void:
	pass
