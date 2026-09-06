extends Node

@warning_ignore("unused_signal")
signal finished

enum Status {
	CHECKING,
	UP_TO_DATE,
	OUT_OF_DATE,
	NEWER_THAN_UPSTREAM,
	FAILED,
}

var version: Version = Version.new(ProjectSettings.get_setting("application/config/version"))
var latest_version: Version
var latest_release_url: String
var status: Status = Status.CHECKING


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	check_for_updates()


func check_for_updates() -> void:
	if not Config.check_for_updates:
		return
	status = Status.CHECKING
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	# Fetching latest release doesn't include pre-releases
	http.request("https://codeberg.org/api/v1/repos/godot-dash/godot-dash/releases")
	http.request_completed.connect(_on_request_completed)
	await http.request_completed
	http.queue_free()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	finished.emit.call_deferred()
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (result == OK and response_code == 200 and data is Array):
		status = Status.FAILED
		return
	if data.is_empty():
		status = Status.FAILED
		return
	latest_version = Version.new(data[0].tag_name.trim_prefix("v"))
	latest_release_url = data[0].html_url
	if latest_version.is_equal_to(version):
		status = Status.UP_TO_DATE
	elif latest_version.is_greater_than(version):
		status = Status.OUT_OF_DATE
	else:
		status = Status.NEWER_THAN_UPSTREAM
