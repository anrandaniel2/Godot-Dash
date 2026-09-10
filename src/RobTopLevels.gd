class_name RobTopLevels
extends Node
## Read-only client for RobTop's public Geometry Dash level endpoints.
##
## No account password or token is needed for searching/downloading public
## levels. Requests are deliberately one-shot and uncached at the HTTP layer;
## downloaded levels are converted into the normal local Godot Dash format.

# Exact public endpoints documented by boomlings.dev. Keep these explicit
# instead of constructing URLs from a base path: endpoint revisions are part
# of RobTop's protocol (`21` for search and `22` for level downloads).
const SEARCH_URL := "https://www.boomlings.com/database/getGJLevels21.php"
const DOWNLOAD_URL := "https://www.boomlings.com/database/downloadGJLevel22.php"
const COMMON_SECRET := "Wmfd2893gb7"
const GAME_VERSION := "22"
const PC_BINARY_VERSION := "47"
const MOBILE_BINARY_VERSION := "48"
const PAGE_SIZE := 10


func search(query: String, page: int = 0, category: int = 4) -> Dictionary:
	var clean_query := query.strip_edges()
	var fields := {
		"secret": COMMON_SECRET,
		"gameVersion": GAME_VERSION,
		"binaryVersion": _binary_version(),
		"type": str(category) if clean_query.is_empty() else "0",
		"str": clean_query,
		"page": str(maxi(0, page)),
		"total": "0",
		"len": "-",
		"diff": "-",
	}
	var response := await _post(SEARCH_URL, fields)
	if not response.ok:
		return response
	var text: String = response.text
	if text == "-1" or text.is_empty():
		return {"ok": true, "levels": [], "page": page, "pages": 0, "total": 0}
	var sections := text.split("#", true)
	if sections.size() < 4:
		return _error("RobTop returned an incomplete level list")

	var creators: Dictionary[String, String] = {}
	for raw_creator: String in sections[1].split("|", false):
		var values := raw_creator.split(":", true)
		if values.size() >= 2:
			creators[values[0]] = values[1]

	var levels: Array[Dictionary] = []
	for raw_level: String in sections[0].split("|", false):
		var values := _pairs(raw_level, ":")
		var level_id := int(values.get("1", "0"))
		if level_id <= 0:
			continue
		var player_id: String = values.get("6", "0")
		levels.append({
			"id": level_id,
			"name": values.get("2", "Level %d" % level_id),
			"creator": creators.get(player_id, "Unknown"),
			"description": _decode_base64(values.get("3", "")),
			"difficulty": _difficulty(values),
			"difficulty_value": _difficulty_value(values),
			"downloads": int(values.get("10", "0")),
			"likes": int(values.get("14", "0")),
			"stars": int(values.get("18", "0")),
			"length": int(values.get("15", "0")),
			"custom_song_id": int(values.get("35", "0")),
		})

	var page_info := sections[3].split(":", true)
	var total := int(page_info[0]) if not page_info.is_empty() else levels.size()
	return {
		"ok": true,
		"levels": levels,
		"page": page,
		"pages": ceili(float(total) / PAGE_SIZE),
		"total": total,
	}


## Downloads and converts one public GD level. The returned `level_data` is the
## same dictionary used by LevelBuildJob and local saves.
func download(level_id: int, summary: Dictionary = {}) -> Dictionary:
	var response := await _post(DOWNLOAD_URL, {
		"secret": COMMON_SECRET,
		"gameVersion": GAME_VERSION,
		"binaryVersion": _binary_version(),
		"dvs": _platform_id(),
		"levelID": str(level_id),
		"inc": "0",
		"extras": "0",
	})
	if not response.ok:
		return response
	var text: String = response.text
	if text == "-1" or text.is_empty():
		return _error("Level %d was not found or is unavailable" % level_id)
	var sections := text.split("#", true)
	var values := _pairs(sections[0], ":")
	var encoded: String = values.get("4", "")
	var level_string := GMD.decode_level_string(encoded)
	if level_string.is_empty():
		return _error("RobTop returned level %d without readable object data" % level_id)

	var level_name: String = values.get("2", summary.get("name", "Level %d" % level_id))
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_level_string(level_string, level_name, report)
	level_data.name = level_name
	level_data.creator = summary.get("creator", "Unknown")
	level_data.description = _decode_base64(values.get("3", ""))
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(values.get("10", summary.get("downloads", 0)))
	level_data["robtop_likes"] = int(values.get("14", summary.get("likes", 0)))
	return {"ok": true, "level_data": level_data, "report": report}


static func _binary_version() -> String:
	return MOBILE_BINARY_VERSION if OS.has_feature("android") or OS.has_feature("ios") else PC_BINARY_VERSION


static func _platform_id() -> String:
	if OS.has_feature("android"):
		return "2"
	if OS.has_feature("windows"):
		return "3"
	if OS.has_feature("macos"):
		return "8"
	# RobTop has no Linux platform value. Anonymous reads do not require dvs;
	# Windows is the closest desktop wire format and the field is optional.
	return "3"


func _post(url: String, fields: Dictionary) -> Dictionary:
	# Keep diagnostics metadata-only: never log request bodies or credentials.
	# Android logcat tags Godot's print output as `godot`, making these lines
	# usable even when package-name filtering only captures system messages.
	print("[RobTop] POST %s" % url)
	var request := HTTPRequest.new()
	# DNS and TLS connection setup can block the main thread when HTTPRequest
	# uses its default non-threaded mode. On affected Android networks that
	# froze both the loading UI and our watchdog before either could update.
	# Run transport work off the render/UI thread so timeout and cancellation
	# remain functional even if Cloudflare's connection stalls.
	request.use_threads = true
	request.timeout = 15.0
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, headers: PackedStringArray, bytes: PackedByteArray) -> void:
		completed.assign([result, status, headers, bytes])
	)
	var body_parts := PackedStringArray()
	for key: String in fields:
		body_parts.append("%s=%s" % [key.uri_encode(), str(fields[key]).uri_encode()])
	var error := request.request(
			url,
			PackedStringArray([
				"Content-Type: application/x-www-form-urlencoded",
				"User-Agent:", # RobTop rejects many non-empty user agents.
				"Accept: text/plain",
			]),
			HTTPClient.METHOD_POST,
			"&".join(body_parts),
	)
	if error != OK:
		request.queue_free()
		push_warning("[RobTop] request could not start: error %d" % error)
		return _error("Could not start the RobTop request (error %d)" % error)

	var deadline := Time.get_ticks_msec() + 15_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		push_warning("[RobTop] timed out after 15 seconds: %s" % url)
		return _error("RobTop did not respond within 15 seconds")

	request.queue_free()
	var result: int = completed[0]
	var status: int = completed[1]
	var bytes: PackedByteArray = completed[3]
	print("[RobTop] result=%d HTTP=%d bytes=%d" % [result, status, bytes.size()])
	if result != HTTPRequest.RESULT_SUCCESS:
		return _error("RobTop connection failed (result %d)" % result)
	if status < 200 or status >= 300:
		return _error("RobTop server returned HTTP %d" % status)
	return {"ok": true, "text": bytes.get_string_from_utf8().strip_edges()}


static func _pairs(text: String, separator: String) -> Dictionary[String, String]:
	var result: Dictionary[String, String] = {}
	var fields := text.split(separator, true)
	for index in range(0, fields.size() - 1, 2):
		result[fields[index]] = fields[index + 1]
	return result


static func _decode_base64(encoded: String) -> String:
	if encoded.is_empty():
		return ""
	var normal := encoded.replace("-", "+").replace("_", "/")
	while normal.length() % 4 != 0:
		normal += "="
	return Marshalls.base64_to_utf8(normal)


static func _difficulty(values: Dictionary[String, String]) -> String:
	if int(values.get("25", "0")) != 0:
		return "Auto"
	if int(values.get("17", "0")) != 0:
		match int(values.get("43", "0")):
			3: return "Easy Demon"
			4: return "Medium Demon"
			5: return "Insane Demon"
			6: return "Extreme Demon"
			_: return "Hard Demon"
	match int(values.get("9", "0")):
		10: return "Easy"
		20: return "Normal"
		30: return "Hard"
		40: return "Harder"
		50: return "Insane"
		_: return "Unrated"


static func _difficulty_value(values: Dictionary[String, String]) -> int:
	if int(values.get("25", "0")) != 0:
		return 0
	if int(values.get("17", "0")) != 0:
		return 5
	return clampi(int(values.get("9", "0")) / 10, 0, 5)


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
