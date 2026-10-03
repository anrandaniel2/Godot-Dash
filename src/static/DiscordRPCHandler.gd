extends Node
class_name DiscordRPCHandler
## Discord Rich Presence used to be provided by the `discord-rpc-gd` addon, a GDExtension binding
## for the native Discord Game SDK. This project is pure GDScript, so that addon (and with it
## Rich Presence support) has been removed.
##
## This class is kept as a no-op stub so that existing call sites keep compiling. All of them are
## guarded by [member DiscordRPCManager.available], which is always [code]false[/code].


static func set_app_id(_id: int) -> void:
	pass


static func set_large_image(_image: String) -> void:
	pass


static func set_start_timestamp(_timestamp: int) -> void:
	pass


static func set_details(_details: String) -> void:
	pass


static func run_callbacks() -> void:
	pass


static func refresh() -> void:
	pass


static func clear() -> void:
	pass


static func unclear() -> void:
	pass
