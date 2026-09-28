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
const SONG_INFO_URL := "https://www.boomlings.com/database/getGJSongInfo.php"
# The bare host follows a distinct CDN route on some mobile networks. Use it
# only after bounded retries on the canonical endpoint; permanent 4xx protocol
# failures must remain visible rather than being hidden by host switching.
const SONG_INFO_FALLBACK_URL := "https://boomlings.com/database/getGJSongInfo.php"
const COMMON_SECRET := "Wmfd2893gb7"
const MAX_SONG_BYTES := 64 * 1024 * 1024
const GAME_VERSION := "22"
const PC_BINARY_VERSION := "47"
const MOBILE_BINARY_VERSION := "48"
const PAGE_SIZE := 10
const TRANSIENT_HTTP_STATUSES := [408, 425, 429, 500, 502, 503, 504]
const NETWORK_ATTEMPTS := 3


func search(query: String, page: int = 0, category: int = 4) -> Dictionary:
	if OS.has_feature("web"):
		var web_res := await _search_web(query, page, category)
		if web_res.ok:
			return web_res
		push_warning("[RobTop] Web search fallback to boomlings: %s" % str(web_res.get("error", "")))

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


func _search_web(query: String, page: int, category: int) -> Dictionary:
	var clean_query := query.strip_edges()
	var target_query := clean_query if not clean_query.is_empty() else "*"
	var cat_map := {
		4: "recent",
		3: "trending",
		1: "mostDownloaded",
		2: "mostLiked",
		6: "featured",
		11: "awarded",
	}
	var url := "https://gdbrowser.com/api/search/%s?page=%d&count=%d" % [
		target_query.uri_encode(),
		page,
		PAGE_SIZE,
	]
	if clean_query.is_empty() and cat_map.has(category):
		url += "&type=" + cat_map[category]

	print("[RobTop] Web search: %s" % url)
	var res := await _get_json(url)
	if not res.ok:
		return res
	var data: Variant = res.data
	if not (data is Array):
		return {"ok": true, "levels": [], "page": page, "pages": 0, "total": 0}

	var levels: Array[Dictionary] = []
	var total := 0
	var pages := 0
	for item in data:
		if not (item is Dictionary):
			continue
		var level_id := int(item.get("id", 0))
		if level_id <= 0:
			continue
		if total == 0:
			total = int(item.get("results", data.size()))
			pages = int(item.get("pages", ceili(float(total) / PAGE_SIZE)))
		levels.append({
			"id": level_id,
			"name": str(item.get("name", "Level %d" % level_id)),
			"creator": str(item.get("author", "Unknown")),
			"description": str(item.get("description", "")),
			"difficulty": str(item.get("difficulty", "NA")),
			"difficulty_value": _difficulty_from_string(str(item.get("difficulty", ""))),
			"downloads": int(item.get("downloads", 0)),
			"likes": int(item.get("likes", 0)),
			"stars": int(item.get("stars", 0)),
			"length": _length_from_string(str(item.get("length", ""))),
			"custom_song_id": int(item.get("customSong", 0)),
			"song_link": str(item.get("songLink", "")),
		})
	return {
		"ok": true,
		"levels": levels,
		"page": page,
		"pages": pages,
		"total": total,
	}


## Downloads and converts one public GD level. The returned `level_data` is the
## same dictionary used by LevelBuildJob and local saves.
func download(level_id: int, summary: Dictionary = {}) -> Dictionary:
	if OS.has_feature("web"):
		var web_res := await _download_gdbrowser(level_id, summary)
		if web_res.ok:
			return web_res
		push_warning("[RobTop] Web GDBrowser download fallback to GDHistory: %s" % str(web_res.get("error", "")))
		var gd_res := await _download_gdhistory(level_id, summary)
		if gd_res.ok:
			return gd_res
		push_warning("[RobTop] Web GDHistory download fallback to boomlings: %s" % str(gd_res.get("error", "")))

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
	# downloadGJLevel22 is documented as
	#   level#hash1#hash2#user#songs#extraArtistNames
	# (only the first three sections on older binary versions). Reject a
	# truncated response instead of accidentally treating metadata as level data.
	var sections := text.split("#", true)
	if sections.size() < 3 or not _looks_like_sha1(sections[1]) or not _looks_like_sha1(sections[2]):
		return _error("RobTop returned a malformed or incomplete level download")
	var values := _pairs(sections[0], ":")
	var encoded: String = values.get("4", "")
	if encoded.is_empty():
		return _error("RobTop returned level %d without compressed object data" % level_id)
	# Online imports on desktop/mobile are required to use the dedicated C++
	# decoder/parser. Web builds use the pure GDScript parser fallback.
	if not NativeCore.available() and not OS.has_feature("web"):
		return _error("The online C++ level parser is unavailable in this build. Reinstall the latest APK.")
	var level_string := GMD.decode_level_string(encoded)
	if level_string.is_empty():
		return _error("RobTop returned level %d without readable object data" % level_id)

	var level_name: String = values.get("2", summary.get("name", "Level %d" % level_id))
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, level_name, report)
	var imported_objects: Array = level_data.get("layers", [{}])[0].get("objects", [])
	print("[RobTop] native conversion: %s" % report.summary())
	if imported_objects.is_empty():
		return _error("Level %d contains no objects supported by the online C++ parser (%s)" % [level_id, report.summary()])
	level_data.name = level_name
	level_data.creator = summary.get("creator", "Unknown")
	level_data.description = _decode_base64(values.get("3", ""))
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(values.get("10", summary.get("downloads", 0)))
	level_data["robtop_likes"] = int(values.get("14", summary.get("likes", 0)))

	# The object string only contains timing. Song identity lives in the level
	# response (12 = built-in song, 35 = custom/Newgrounds song), so importing
	# objects alone necessarily produced silent online levels. Download custom
	# music anonymously from the URL RobTop returns and point the ordinary level
	# player at the cached file. A music failure does not discard a valid level.
	level_data.song_start_time = maxf(0.0, float(level_data.get("song_start_time", 0.0)))
	var audio_warning := ""
	var custom_song_id := int(values.get("35", summary.get("custom_song_id", 0)))
	var official_song_id := int(values.get("12", "0"))
	var song_link: String = summary.get("song_link", "")
	if custom_song_id > 0:
		var song := await _download_custom_song(custom_song_id, song_link)
		if song.ok:
			level_data.song_path = song.file_name
		else:
			audio_warning = song.error
	elif official_song_id > 0:
		audio_warning = "This level uses built-in Geometry Dash song %d, which is not included in Godot Dash." % official_song_id

	return {
		"ok": true,
		"level_data": level_data,
		"report": report,
		"audio_warning": audio_warning,
	}


func _download_gdbrowser(level_id: int, summary: Dictionary = {}) -> Dictionary:
	var url := "https://gdbrowser.com/api/level/%d?download=1" % level_id
	print("[RobTop] Web level download via GDBrowser: %s" % url)
	var res := await _get_json(url)
	if not res.ok:
		return _error("GDBrowser download request failed: %s" % str(res.get("error", "")))
	var data: Variant = res.get("data")
	if not (data is Dictionary):
		return _error("Level %d was not found on GDBrowser" % level_id)
	var dict_data: Dictionary = data
	var encoded: String = str(dict_data.get("data", "")).strip_edges()
	if encoded.is_empty() or encoded == "-1":
		return _error("Level %d has no downloadable data on GDBrowser" % level_id)

	var level_string := GMD.decode_level_string(encoded)
	if level_string.is_empty():
		return _error("Level %d data could not be decompressed" % level_id)

	var level_name: String = str(dict_data.get("name", summary.get("name", "Level %d" % level_id)))
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, level_name, report)
	var imported_objects: Array = level_data.get("layers", [{}])[0].get("objects", [])
	print("[RobTop] GDBrowser conversion: %s" % report.summary())
	if imported_objects.is_empty():
		return _error("Level %d contains no objects supported by parser (%s)" % [level_id, report.summary()])

	level_data.name = level_name
	level_data.creator = str(dict_data.get("author", summary.get("creator", "Unknown")))
	level_data.description = str(dict_data.get("description", summary.get("description", "")))
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(dict_data.get("downloads", summary.get("downloads", 0)))
	level_data["robtop_likes"] = int(dict_data.get("likes", summary.get("likes", 0)))

	level_data.song_start_time = maxf(0.0, float(level_data.get("song_start_time", 0.0)))
	var audio_warning := ""
	var custom_song_id := int(dict_data.get("customSong", summary.get("custom_song_id", 0)))
	var official_song_id := int(dict_data.get("officialSong", summary.get("official_song_id", 0)))
	var song_link: String = str(dict_data.get("songLink", summary.get("song_link", "")))

	if custom_song_id > 0:
		var song := await _download_custom_song(custom_song_id, song_link)
		if song.ok:
			level_data.song_path = song.file_name
		else:
			audio_warning = song.error
	elif official_song_id > 0:
		audio_warning = "This level uses built-in Geometry Dash song %d, which is not included in Godot Dash." % official_song_id

	return {
		"ok": true,
		"level_data": level_data,
		"report": report,
		"audio_warning": audio_warning,
	}


func _download_gdhistory(level_id: int, summary: Dictionary = {}) -> Dictionary:
	var info_url := "https://history.geometrydash.eu/api/v1/level/%d/" % level_id
	if OS.has_feature("web"):
		info_url = "https://api.allorigins.win/raw?url=" + info_url.uri_encode()
	print("[RobTop] Web level download via GDHistory: %s" % info_url)
	var info_res := await _get_json(info_url)
	if not info_res.ok:
		return _error("Level %d not found in online archive (%s)" % [level_id, info_res.error])
	var data: Dictionary = info_res.data if (info_res.data is Dictionary) else {}
	var records: Array = data.get("records", [])
	var chosen_record_id := -1
	for record: Variant in records:
		if not (record is Dictionary):
			continue
		if bool(record.get("level_string_available", false)) and not bool(record.get("is_invalid", false)):
			var rid := int(record.get("id", -1))
			if str(record.get("record_type", "")) == "download":
				chosen_record_id = rid
				break
			elif chosen_record_id == -1 or rid > chosen_record_id:
				chosen_record_id = rid
	if chosen_record_id == -1:
		return _error("Level %d has no downloadable string in online archive" % level_id)

	var download_url := "https://history.geometrydash.eu/level/%d/%d/download/" % [level_id, chosen_record_id]
	if OS.has_feature("web"):
		download_url = "https://api.allorigins.win/raw?url=" + download_url.uri_encode()
	print("[RobTop] Fetching level plist: %s" % download_url)
	var text_res := await _get_text(download_url)
	if not text_res.ok:
		return _error("Could not download level file from archive (%s)" % text_res.error)
	var gmd_text: String = text_res.text
	var doc := GMD.parse(gmd_text)
	var level_string := ""
	if doc != null and not doc.level_string.is_empty():
		level_string = doc.level_string
	else:
		var encoded := _extract_k4(gmd_text)
		if not encoded.is_empty():
			level_string = GMD.decode_level_string(encoded)

	if level_string.is_empty():
		return _error("Archived level string could not be decompressed")

	var level_name: String = summary.get("name", "")
	if level_name.is_empty() and doc != null:
		level_name = doc.get_string(GMD.Key.NAME)
	if level_name.is_empty():
		level_name = str(data.get("cache_level_name", "Level %d" % level_id))

	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, level_name, report)
	var imported_objects: Array = level_data.get("layers", [{}])[0].get("objects", [])
	print("[RobTop] GDHistory conversion: %s" % report.summary())
	if imported_objects.is_empty():
		return _error("Level %d contains no objects supported by parser" % level_id)

	level_data.name = level_name
	var creator_name: String = summary.get("creator", "")
	if creator_name.is_empty() and doc != null:
		creator_name = doc.get_string(GMD.Key.CREATOR)
	if creator_name.is_empty():
		creator_name = str(data.get("cache_username", "Unknown"))
	level_data.creator = creator_name

	level_data.description = summary.get("description", "")
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(summary.get("downloads", data.get("cache_downloads", 0)))
	level_data["robtop_likes"] = int(summary.get("likes", data.get("cache_likes", 0)))

	level_data.song_start_time = maxf(0.0, float(level_data.get("song_start_time", 0.0)))
	var audio_warning := ""
	var custom_song_id := int(summary.get("custom_song_id", 0))
	if custom_song_id == 0 and doc != null:
		custom_song_id = doc.get_int(GMD.Key.SONG_ID)
	if custom_song_id == 0:
		custom_song_id = int(data.get("cache_song_id", 0))

	var official_song_id := int(summary.get("official_song_id", 0))
	if official_song_id == 0 and doc != null:
		official_song_id = doc.get_int(GMD.Key.OFFICIAL_SONG)
	if official_song_id == 0:
		official_song_id = int(data.get("cache_audiotrack", 0))

	var song_link: String = summary.get("song_link", "")

	if custom_song_id > 0:
		var song := await _download_custom_song(custom_song_id, song_link)
		if song.ok:
			level_data.song_path = song.file_name
		else:
			audio_warning = song.error
	elif official_song_id > 0:
		audio_warning = "This level uses built-in Geometry Dash song %d, which is not included in Godot Dash." % official_song_id

	return {
		"ok": true,
		"level_data": level_data,
		"report": report,
		"audio_warning": audio_warning,
	}


## Resolves and caches a custom song without account credentials. RobTop's song
## object provides a percent-encoded HTTPS media URL in field 10.
func _download_custom_song(song_id: int, direct_url: String = "") -> Dictionary:
	var file_name := "robtop_%d.mp3" % song_id
	var final_path := Constants.SONG_DIR + file_name
	if FileAccess.file_exists(final_path):
		var cached := FileAccess.open(final_path, FileAccess.READ)
		if cached != null and cached.get_length() > 0:
			return {"ok": true, "file_name": file_name}

	var media_url := direct_url
	var extension := "mp3"
	if media_url.is_empty():
		if OS.has_feature("web"):
			media_url = "https://geometrydashcontent.b-cdn.net/songs/%d.mp3" % song_id
		else:
			var song_fields := {
				"secret": COMMON_SECRET,
				"gameVersion": GAME_VERSION,
				"binaryVersion": _binary_version(),
				"songID": str(song_id),
			}
			var info := await _post(SONG_INFO_URL, song_fields)
			if not info.ok and bool(info.get("retryable", false)):
				push_warning("[RobTop] canonical song-info route unavailable; trying fallback host")
				info = await _post(SONG_INFO_FALLBACK_URL, song_fields)
			if not info.ok:
				media_url = "https://geometrydashcontent.b-cdn.net/songs/%d.mp3" % song_id
			elif info.text == "-1" or info.text == "-2":
				return _error("Music %d is unavailable or not permitted by its host." % song_id)
			else:
				var song_values := _pairs(info.text, "~|~")
				media_url = song_values.get("10", "").uri_decode()
				if media_url.begins_with("http://"):
					media_url = "https://" + media_url.trim_prefix("http://")

	if media_url.begins_with("http://"):
		media_url = "https://" + media_url.trim_prefix("http://")
	if not media_url.begins_with("https://"):
		return _error("Music %d has no secure download URL." % song_id)
	var url_path := media_url.get_slice("?", 0)
	var detected_ext := url_path.get_extension().to_lower()
	if detected_ext in ["mp3", "ogg", "wav"]:
		extension = detected_ext
		file_name = "robtop_%d.%s" % [song_id, extension]
		final_path = Constants.SONG_DIR + file_name
		if FileAccess.file_exists(final_path):
			var cached := FileAccess.open(final_path, FileAccess.READ)
			if cached != null and cached.get_length() > 0:
				return {"ok": true, "file_name": file_name}

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Constants.SONG_DIR))
	var temporary_path := final_path + ".download"
	if FileAccess.file_exists(temporary_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
	var downloaded := await _download_audio(media_url, temporary_path)
	if not downloaded.ok:
		if FileAccess.file_exists(temporary_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return downloaded
	var downloaded_file := FileAccess.open(temporary_path, FileAccess.READ)
	var downloaded_size := downloaded_file.get_length() if downloaded_file != null else 0
	if downloaded_size <= 0 or downloaded_size > MAX_SONG_BYTES:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return _error("Music %d returned an empty or oversized audio file." % song_id)
	var bytes := downloaded_file.get_buffer(downloaded_size)
	if not _looks_like_audio(bytes, extension):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return _error("Music %d returned an invalid or oversized audio file." % song_id)
	var rename_error := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(temporary_path),
			ProjectSettings.globalize_path(final_path),
	)
	if rename_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return _error("Music %d could not be saved (error %d)." % [song_id, rename_error])
	print("[RobTop] cached song %d: %s (%d bytes)" % [song_id, file_name, bytes.size()])
	return {"ok": true, "file_name": file_name}


func _download_audio(url: String, destination: String) -> Dictionary:
	var last: Dictionary = _error("Music download failed.")
	for attempt in NETWORK_ATTEMPTS:
		if FileAccess.file_exists(destination):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(destination))
		last = await _download_audio_once(url, destination)
		if last.ok or not bool(last.get("retryable", false)):
			return last
		if attempt + 1 < NETWORK_ATTEMPTS:
			var delay := 0.5 * pow(2.0, attempt)
			push_warning("[RobTop] transient music failure; retry %d/%d in %.1fs" % [attempt + 2, NETWORK_ATTEMPTS, delay])
			await get_tree().create_timer(delay).timeout
	return last


static func _resolve_url(endpoint: String, proxy_prefix: String = "") -> String:
	if not OS.has_feature("web"):
		return endpoint
	# CDNs and open APIs (gdbrowser.com, history.geometrydash.eu, b-cdn.net) provide
	# full CORS headers natively. Only boomlings.com requires a CORS proxy on Web.
	if "boomlings.com" not in endpoint:
		return endpoint
	if proxy_prefix.is_empty():
		proxy_prefix = str(ProjectSettings.get_setting("network/cors_proxy", ""))
	if proxy_prefix.is_empty():
		proxy_prefix = "https://api.cors.lol/?url="
	if proxy_prefix.contains("?"):
		return proxy_prefix + endpoint.uri_encode()
	return proxy_prefix + endpoint


func _get_json(url: String) -> Dictionary:
	var response := await _get_text(url)
	if not response.ok:
		return response
	var text: String = response.text
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return _error("Failed to parse JSON response: %s" % json.get_error_message())
	return {"ok": true, "data": json.data}


func _get_text(url: String) -> Dictionary:
	var target_url := _resolve_url(url)
	print("[RobTop] GET %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 15.0
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, headers: PackedStringArray, bytes: PackedByteArray) -> void:
		completed.assign([result, status, headers, bytes])
	)
	var headers := PackedStringArray(["Accept: application/json, text/plain, */*"])
	if not OS.has_feature("web"):
		headers.append("User-Agent: Godot-Dash/1")
	var error := request.request(target_url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		request.queue_free()
		return _error("Could not start GET request (error %d)" % error)
	var deadline := Time.get_ticks_msec() + 15_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		return {"ok": false, "error": "Request timed out after 15 seconds", "retryable": true}
	request.queue_free()
	var result: int = completed[0]
	var status: int = completed[1]
	var bytes: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and result == HTTPRequest.RESULT_CANT_CONNECT
		if is_cors:
			return {"ok": false, "error": "Request blocked by browser CORS policy", "retryable": false}
		return {"ok": false, "error": "Request failed (result %d)" % result, "retryable": true}
	if status < 200 or status >= 300:
		return {"ok": false, "error": "Server returned HTTP %d" % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	return {"ok": true, "text": bytes.get_string_from_utf8().strip_edges()}


func _download_audio_once(url: String, destination: String) -> Dictionary:
	var target_url := _resolve_url(url)
	print("[RobTop] GET custom song from %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 30.0
	request.max_redirects = 5
	request.download_file = destination
	request.body_size_limit = MAX_SONG_BYTES
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.assign([result, status])
	)
	var headers := PackedStringArray(["Accept: audio/*"])
	if not OS.has_feature("web"):
		headers.append("User-Agent: Godot-Dash/1")
	var error := request.request(target_url, headers)
	if error != OK:
		request.queue_free()
		return _error("Could not start the music download (error %d)." % error)
	var deadline := Time.get_ticks_msec() + 30_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		return {"ok": false, "error": "Music download timed out after 30 seconds.", "retryable": true}
	request.queue_free()
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and int(completed[0]) == HTTPRequest.RESULT_CANT_CONNECT
		if is_cors:
			return {"ok": false, "error": "Music download blocked by browser CORS policy.", "retryable": false}
		return {"ok": false, "error": "Music download failed (result %d)." % int(completed[0]), "retryable": true}
	var status := int(completed[1])
	if status < 200 or status >= 300:
		return {"ok": false, "error": "Music host returned HTTP %d." % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	return {"ok": true}


static func _looks_like_audio(bytes: PackedByteArray, extension: String) -> bool:
	if bytes.size() < 4:
		return false
	if extension == "ogg":
		return bytes.slice(0, 4).get_string_from_ascii() == "OggS"
	if extension == "wav":
		return bytes.slice(0, 4).get_string_from_ascii() == "RIFF"
	# MP3 may start with ID3 metadata or directly with an MPEG frame sync.
	return bytes.slice(0, 3).get_string_from_ascii() == "ID3" or (bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0)


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
	var last: Dictionary = _error("RobTop request failed.")
	var proxies: PackedStringArray = []
	if OS.has_feature("web"):
		var custom_proxy := str(ProjectSettings.get_setting("network/cors_proxy", ""))
		if not custom_proxy.is_empty():
			proxies.append(custom_proxy)
		for fallback in ["https://api.cors.lol/?url=", "https://corsproxy.org/?url=", "https://proxy.corsfix.com/?"]:
			if fallback not in proxies:
				proxies.append(fallback)
	else:
		proxies.append("")

	for attempt in proxies.size():
		var proxy_override := proxies[attempt]
		last = await _post_once(url, fields, proxy_override)
		if last.ok:
			return last
		if not bool(last.get("retryable", false)) and not OS.has_feature("web"):
			return last
		if attempt + 1 < proxies.size():
			var delay := 0.3 * pow(1.5, attempt)
			push_warning("[RobTop] request failed (%s); trying fallback proxy in %.1fs" % [last.get("error", ""), delay])
			await get_tree().create_timer(delay).timeout
	return last


func _post_once(url: String, fields: Dictionary, proxy_override: String = "") -> Dictionary:
	# Keep diagnostics metadata-only: never log request bodies or credentials.
	# Android logcat tags Godot's print output as `godot`, making these lines
	# usable even when package-name filtering only captures system messages.
	var target_url := _resolve_url(url, proxy_override)
	print("[RobTop] POST %s" % target_url)
	var request := HTTPRequest.new()
	# DNS and TLS connection setup can block the main thread when HTTPRequest
	# uses its default non-threaded mode. On affected Android networks that
	# froze both the loading UI and our watchdog before either could update.
	# On the Web platform, HTTPClientWeb does not support blocking mode.
	request.use_threads = not OS.has_feature("web")
	request.timeout = 15.0
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, headers: PackedStringArray, bytes: PackedByteArray) -> void:
		completed.assign([result, status, headers, bytes])
	)
	var body_parts := PackedStringArray()
	for key: String in fields:
		body_parts.append("%s=%s" % [key.uri_encode(), str(fields[key]).uri_encode()])
	var headers := PackedStringArray([
		"Content-Type: application/x-www-form-urlencoded",
		"Accept: text/plain",
	])
	if not OS.has_feature("web"):
		headers.append("User-Agent:") # RobTop rejects many non-empty user agents on native sockets.
	var error := request.request(
			target_url,
			headers,
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
		return {"ok": false, "error": "RobTop did not respond within 15 seconds", "retryable": true}

	request.queue_free()
	var result: int = completed[0]
	var status: int = completed[1]
	var bytes: PackedByteArray = completed[3]
	print("[RobTop] result=%d HTTP=%d bytes=%d" % [result, status, bytes.size()])
	if result != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and result == HTTPRequest.RESULT_CANT_CONNECT
		if is_cors:
			return {
				"ok": false,
				"error": "RobTop connection blocked by browser CORS policy. Set network/cors_proxy or use desktop/Android.",
				"retryable": OS.has_feature("web"),
			}
		return {"ok": false, "error": "RobTop connection failed (result %d)" % result, "retryable": true}
	if status == 401 or status == 403:
		return {
			"ok": false,
			"error": "Proxy returned HTTP %d. Set a custom CORS proxy in settings." % status,
			"status": status,
			"retryable": OS.has_feature("web"),
		}
	if status < 200 or status >= 300:
		return {"ok": false, "error": "RobTop server returned HTTP %d" % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	return {"ok": true, "text": bytes.get_string_from_utf8().strip_edges()}


static func _pairs(text: String, separator: String) -> Dictionary[String, String]:
	var result: Dictionary[String, String] = {}
	var fields := text.split(separator, true)
	for index in range(0, fields.size() - 1, 2):
		result[fields[index]] = fields[index + 1]
	return result


static func _looks_like_sha1(value: String) -> bool:
	if value.length() != 40:
		return false
	for character: String in value.to_lower():
		if character not in "0123456789abcdef":
			return false
	return true


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


static func _difficulty_from_string(diff: String) -> int:
	var d := diff.to_lower()
	if "auto" in d:
		return 0
	if "easy" in d and "demon" not in d:
		return 1
	if "normal" in d:
		return 2
	if "harder" in d:
		return 4
	if "hard" in d and "demon" not in d:
		return 3
	if "insane" in d and "demon" not in d:
		return 5
	if "demon" in d:
		return 5
	return 0


static func _length_from_string(length_str: String) -> int:
	match length_str.to_lower():
		"tiny": return 0
		"short": return 1
		"medium": return 2
		"long": return 3
		"xl": return 4
		"plat", "platformer": return 5
		_: return 0


static func _extract_k4(plist_text: String) -> String:
	var doc := GMD.parse(plist_text)
	if doc != null and not doc.level_string.is_empty():
		return doc.level_string
	var k_pos := plist_text.find("<k>k4</k>")
	if k_pos == -1:
		k_pos = plist_text.find("<k>k4 </k>")
	if k_pos == -1:
		return ""
	var s_start := plist_text.find("<s>", k_pos)
	if s_start == -1:
		return ""
	s_start += 3
	var s_end := plist_text.find("</s>", s_start)
	if s_end == -1:
		return ""
	return plist_text.substr(s_start, s_end - s_start).strip_edges()


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
