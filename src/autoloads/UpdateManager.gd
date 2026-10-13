extends Node

@warning_ignore("unused_signal")
signal finished

enum Status {
	CHECKING,
	UP_TO_DATE,
	OUT_OF_DATE,
	NEWER_THAN_UPSTREAM,
	FAILED,
	## Web builds (and unmanaged builds/checks disabled): the release API sends no CORS headers, so a
	## browser fetch is rejected before it can return a status - and a Web build
	## cannot update itself anyway. The page hosting the build owns updates.
	DISABLED,
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
		status = Status.DISABLED
		finished.emit.call_deferred()
		return
	if OS.has_feature("web"):
		# Do not fire a request the browser is guaranteed to reject: the fetch
		# would show up as a CORS error plus "TypeError: Failed to fetch" in the
		# page console. Report the host-managed state instead.
		status = Status.DISABLED
		finished.emit.call_deferred()
		return
	if OS.has_feature("windows"):
		await _check_windows_updates()
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


func uses_windows_channel() -> bool:
	return OS.has_feature("windows") and not str(ProjectSettings.get_setting(
		"application/config/windows_update_channel", ""
	)).is_empty()


## Fork builds must not offer an unrelated Codeberg binary as their update.
## The user downloads/runs the installer; no remote executable runs silently.
func _check_windows_updates() -> void:
	if not uses_windows_channel() or OS.get_cmdline_user_args().has("--native-smoke"):
		status = Status.DISABLED
		finished.emit.call_deferred()
		return
	status = Status.CHECKING
	var channel: String = ProjectSettings.get_setting("application/config/windows_update_channel")
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = 12.0
	http.body_size_limit = 1024 * 1024
	add_child(http)
	var error: Error = http.request(
		"https://api.github.com/repos/anrandaniel2/Godot-Dash/releases/tags/%s" % channel,
		PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Godot-Dash"])
	)
	if error != OK:
		http.queue_free()
		status = Status.FAILED
		finished.emit.call_deferred()
		return
	var response: Array = await http.request_completed
	http.queue_free()
	status = Status.FAILED
	if int(response[0]) == HTTPRequest.RESULT_SUCCESS and int(response[1]) == 200:
		var bytes: PackedByteArray = response[3]
		var data: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if data is Dictionary:
			var installed: int = int(ProjectSettings.get_setting("application/config/windows_build_number", 0))
			var update: Dictionary = WindowsUpdatePolicy.evaluate(data, channel, installed)
			if bool(update.get("ok", false)):
				latest_release_url = str(update.url)
				status = Status.OUT_OF_DATE if bool(update.newer) else Status.UP_TO_DATE
	finished.emit.call_deferred()
