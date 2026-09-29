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


func search(query: String, page: int = 0, category: int = 1) -> Dictionary:
	if OS.has_feature("web"):
		var web_res := await _search_web(query, page, category)
		if web_res.ok:
			return web_res
		push_warning("[RobTop] Web search fallback to boomlings: %s" % str(web_res.get("error", "")))

	var clean_query := query.strip_edges()
	var fields := {
		"gameVersion": "21",
		"binaryVersion": "35",
		"gdw": "0",
		"accountID": "0",
		"gjp": "",
		"uuid": "0",
		"type": str(category) if clean_query.is_empty() else "0",
		"str": clean_query,
		"diff": "-",
		"len": "-",
		"page": str(maxi(0, page)),
		"total": "0",
		"uncompleted": "0",
		"onlyCompleted": "0",
		"featured": "0",
		"original": "0",
		"twoPlayer": "0",
		"coins": "0",
		"epic": "0",
		"secret": COMMON_SECRET,
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
		1: "mostdownloaded",
		2: "mostliked",
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
	elif clean_query.is_empty():
		url += "&type=mostdownloaded"

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
		# On Web, try GDBrowser first (native CORS support like GDRWeb), then GDHistory archive, then direct RobTop.
		var gdb_res := await _download_gdbrowser(level_id, summary)
		if gdb_res.ok:
			return gdb_res
		var gd_res := await _download_gdhistory(level_id, summary)
		if gd_res.ok:
			return gd_res
		var direct_res := await _download_direct(level_id, summary)
		if direct_res.ok:
			return direct_res
		return _error("Could not download level %d: %s" % [level_id, gdb_res.get("error", "unavailable")])

	var response := await _download_direct(level_id, summary)
	if response.ok:
		return response
	var gdb_res := await _download_gdbrowser(level_id, summary)
	if gdb_res.ok:
		return gdb_res
	var gd_res := await _download_gdhistory(level_id, summary)
	if gd_res.ok:
		return gd_res
	return response


func _download_direct(level_id: int, summary: Dictionary = {}) -> Dictionary:
	# Matches GDRWeb / RobTop exact client parameters:
	var fields := {
		"gameVersion": "21",
		"binaryVersion": "35",
		"gdw": "0",
		"accountID": "0",
		"gjp": "",
		"uuid": "0",
		"levelID": str(level_id),
		"inc": "1",
		"extras": "0",
		"secret": COMMON_SECRET,
	}
	var response := await _post(DOWNLOAD_URL, fields)
	if not response.ok:
		return response
	var text: String = response.text
	if text == "-1" or text.is_empty():
		return _error("Level %d was not found or is unavailable" % level_id)
	if NativeCore.is_html_error_response(text):
		return _error("Server returned HTML error response instead of level data")

	# downloadGJLevel22 response format per boomlings.dev:
	#   {level}#{hash1}#{hash2}#{user}#{songs}#{extraArtistNames}
	var sections := text.split("#", true)
	if sections.is_empty() or sections[0].is_empty():
		return _error("RobTop returned an empty level response")
	var values := _pairs(sections[0], ":")
	var encoded: String = values.get("4", "")
	if encoded.is_empty():
		return _error("RobTop returned level %d without compressed object data" % level_id)

	var level_string := GMD.decode_level_string(encoded)
	if level_string.is_empty():
		return _error("RobTop returned level %d without readable object data" % level_id)

	var level_name: String = values.get("2", summary.get("name", "Level %d" % level_id))
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, level_name, report)
	var imported_objects: Array = level_data.get("layers", [{}])[0].get("objects", [])
	print("[RobTop] native conversion: %s" % report.summary())
	if imported_objects.is_empty():
		return _error("Level %d contains no objects supported by the online parser (%s)" % [level_id, report.summary()])

	level_data.name = level_name
	var creator_name: String = str(summary.get("creator", ""))
	if (creator_name.is_empty() or creator_name == "Unknown") and sections.size() > 3 and not sections[3].is_empty():
		var user_parts := sections[3].split(":")
		if user_parts.size() >= 2 and not user_parts[1].is_empty():
			creator_name = user_parts[1]
	level_data.creator = creator_name if not creator_name.is_empty() else "Unknown"
	level_data.description = _decode_base64(values.get("3", ""))
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(values.get("10", summary.get("downloads", 0)))
	level_data["robtop_likes"] = int(values.get("14", summary.get("likes", 0)))

	level_data.song_start_time = maxf(0.0, float(level_data.get("song_start_time", 0.0)))
	var audio_warning := ""
	var custom_song_id := int(values.get("35", summary.get("custom_song_id", 0)))
	var official_song_id := int(values.get("12", summary.get("official_song_id", 0)))
	var song_link: String = str(summary.get("song_link", ""))

	# Parse song link from sections[4] ({songs}) of downloadGJLevel22 response if available:
	if song_link.is_empty() and sections.size() > 4 and not sections[4].is_empty():
		for raw_song in sections[4].split("~:~", false):
			var s_pairs := _pairs(raw_song, "~|~")
			if int(s_pairs.get("1", "0")) == custom_song_id:
				song_link = s_pairs.get("10", "").uri_decode()
				break

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
		var analyze_url := "https://gdbrowser.com/api/analyze/%d" % level_id
		print("[RobTop] GDBrowser fallback to analyze: %s" % analyze_url)
		res = await _get_json(analyze_url)
	if not res.ok or not (res.data is Dictionary):
		return _error("Level %d was not found on GDBrowser (%s)" % [level_id, res.get("error", "")])
	var dict_data: Dictionary = res.data
	var raw_data: String = ""
	if dict_data.has("data"):
		raw_data = str(dict_data.get("data", "")).strip_edges()
	elif dict_data.get("level") is Dictionary:
		raw_data = str(dict_data["level"].get("data", "")).strip_edges()

	if raw_data.is_empty() or raw_data == "-1":
		return _error("Level %d has no downloadable data on GDBrowser" % level_id)

	var level_string := GMD.decode_level_string(raw_data)
	if level_string.is_empty():
		return _error("Level %d data could not be parsed" % level_id)

	var level_info: Dictionary = dict_data.get("level", {}) if (dict_data.get("level") is Dictionary) else dict_data
	var level_name: String = str(level_info.get("name", summary.get("name", "Level %d" % level_id)))
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, level_name, report)
	var imported_objects: Array = level_data.get("layers", [{}])[0].get("objects", [])
	print("[RobTop] GDBrowser conversion: %s" % report.summary())
	if imported_objects.is_empty():
		return _error("Level %d contains no objects supported by parser (%s)" % [level_id, report.summary()])

	level_data.name = level_name
	level_data.creator = str(level_info.get("author", summary.get("creator", "Unknown")))
	level_data.description = str(level_info.get("description", summary.get("description", "")))
	level_data.rating = -1
	level_data["robtop_level_id"] = level_id
	level_data["robtop_downloads"] = int(summary.get("downloads", level_info.get("downloads", 0)))
	level_data["robtop_likes"] = int(summary.get("likes", level_info.get("likes", 0)))

	var song_offset := 0.0
	if dict_data.has("settings") and (dict_data["settings"] is Dictionary):
		song_offset = float(dict_data["settings"].get("songOffset", 0.0))
	level_data.song_start_time = maxf(song_offset, float(level_data.get("song_start_time", 0.0)))

	var audio_warning := ""
	var custom_song_id := int(summary.get("custom_song_id", level_info.get("customSong", 0)))
	var official_song_id := int(summary.get("official_song_id", level_info.get("officialSong", 0)))
	var song_link: String = str(summary.get("song_link", level_info.get("songLink", "")))

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
	print("[RobTop] Web level download via GDHistory: %s" % info_url)
	var info_res := await _get_json(info_url)
	if not info_res.ok:
		return _error("Level %d not found in online archive (%s)" % [level_id, info_res.error])
	var data: Dictionary = info_res.data if (info_res.data is Dictionary) else {}
	var records: Array = data.get("records", [])
	var chosen_record_id := -1
	var chosen_version := -1
	for record: Variant in records:
		if not (record is Dictionary):
			continue
		if bool(record.get("level_string_available", false)) and not bool(record.get("is_invalid", false)):
			var rid := int(record.get("id", -1))
			var ver := int(record.get("level_version", 1))
			var is_download := str(record.get("record_type", "")) == "download"
			if is_download:
				if ver > chosen_version or (ver == chosen_version and rid > chosen_record_id):
					chosen_record_id = rid
					chosen_version = ver
			elif chosen_record_id == -1 or rid > chosen_record_id:
				if chosen_version <= 0:
					chosen_record_id = rid
	if chosen_record_id == -1:
		return _error("Level %d has no downloadable string in online archive" % level_id)

	var download_url := "https://history.geometrydash.eu/level/%d/%d/download/" % [level_id, chosen_record_id]
	print("[RobTop] Fetching level archive: %s (record %d, ver %d)" % [download_url, chosen_record_id, chosen_version])
	var text_res := await _get_text(download_url)
	if not text_res.ok:
		return _error("Could not download level file from archive (%s)" % text_res.error)
	var gmd_text: String = text_res.text
	if NativeCore.is_html_error_response(gmd_text):
		return _error("Online archive returned an HTML error response instead of level data")
	if gmd_text.begins_with("{") and gmd_text.contains("\"contents\""):
		var parsed_wrap = JSON.parse_string(gmd_text)
		if parsed_wrap is Dictionary and parsed_wrap.has("contents"):
			gmd_text = str(parsed_wrap["contents"])
	var trimmed_text := gmd_text.strip_edges()
	var doc: GMD.Document = null
	if trimmed_text.begins_with("<?xml") or trimmed_text.begins_with("<plist"):
		doc = GMD.parse(gmd_text)
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
	var proxies: PackedStringArray = [""]
	if OS.has_feature("web"):
		var custom_proxy := _get_custom_proxy()
		if not custom_proxy.is_empty():
			proxies.insert(0, custom_proxy)
		proxies.append("https://api.codetabs.com/v1/proxy?quest=")
		proxies.append("https://api.allorigins.win/raw?url=")
	for attempt in proxies.size():
		var proxy := proxies[attempt]
		var target_url := _resolve_url(url, proxy)
		if FileAccess.file_exists(destination):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(destination))
		last = await _download_audio_once(target_url, destination)
		if last.ok:
			return last
	return last


static func _get_custom_proxy() -> String:
	var p := str(ProjectSettings.get_setting("network/cors_proxy", ""))
	if p.is_empty() and Config != null:
		p = str(Config.cors_proxy)
	if p.is_empty() and Config != null and Config.config_file != null:
		p = str(Config.config_file.get_value("Internet", "cors_proxy", ""))
	return p.strip_edges()


static func _resolve_url(endpoint: String, proxy_prefix: String = "") -> String:
	if not OS.has_feature("web"):
		return endpoint
	if proxy_prefix.is_empty():
		return endpoint
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
	var last := await _get_text_once(url)
	if last.ok or not OS.has_feature("web"):
		return last
	var proxies: PackedStringArray = [
		"https://api.codetabs.com/v1/proxy?quest=",
		"https://api.allorigins.win/raw?url=",
	]
	var custom_proxy := _get_custom_proxy()
	if not custom_proxy.is_empty():
		proxies.insert(0, custom_proxy)
	for proxy in proxies:
		var proxied_url := _resolve_url(url, proxy)
		var res := await _get_text_once(proxied_url)
		if res.ok:
			return res
	return last


func _get_text_once(target_url: String) -> Dictionary:
	print("[RobTop] GET %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 45.0
	request.body_size_limit = -1
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, headers: PackedStringArray, bytes: PackedByteArray) -> void:
		completed.assign([result, status, headers, bytes])
	)
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("Accept: application/json, text/plain, */*")
		headers.append("User-Agent: Godot-Dash/1")
	var error := request.request(target_url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		request.queue_free()
		return _error("Could not start GET request (error %d)" % error)
	var deadline := Time.get_ticks_msec() + 45_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		return {"ok": false, "error": "Request timed out after 45 seconds", "retryable": true}
	request.queue_free()
	var result: int = completed[0]
	var status: int = completed[1]
	var bytes: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and (result == HTTPRequest.RESULT_CANT_CONNECT or result == HTTPRequest.RESULT_CONNECTION_ERROR)
		if is_cors:
			return {"ok": false, "error": "Request blocked by browser CORS policy", "retryable": true}
		return {"ok": false, "error": "Request failed (result %d)" % result, "retryable": true}
	if status < 200 or status >= 300:
		return {"ok": false, "error": "Server returned HTTP %d" % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	return {"ok": true, "text": bytes.get_string_from_utf8().strip_edges()}


func _download_audio_once(url: String, destination: String) -> Dictionary:
	var target_url := _resolve_url(url)
	print("[RobTop] GET custom song from %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 45.0
	request.max_redirects = 5
	request.download_file = destination
	request.body_size_limit = MAX_SONG_BYTES
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.assign([result, status])
	)
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("Accept: audio/*")
		headers.append("User-Agent: Godot-Dash/1")
	var error := request.request(target_url, headers)
	if error != OK:
		request.queue_free()
		return _error("Could not start the music download (error %d)." % error)
	var deadline := Time.get_ticks_msec() + 45_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		return {"ok": false, "error": "Music download timed out after 45 seconds.", "retryable": true}
	request.queue_free()
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and (int(completed[0]) == HTTPRequest.RESULT_CANT_CONNECT or int(completed[0]) == HTTPRequest.RESULT_CONNECTION_ERROR)
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
	return "3"


func _post(url: String, fields: Dictionary) -> Dictionary:
	var custom_proxy := _get_custom_proxy() if OS.has_feature("web") else ""
	return await _post_once(url, fields, custom_proxy)


func _post_once(url: String, fields: Dictionary, proxy_override: String = "") -> Dictionary:
	var target_url := _resolve_url(url, proxy_override)
	print("[RobTop] POST %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 30.0
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
	])
	if not OS.has_feature("web"):
		headers.append("User-Agent:") # RobTop requires empty user agent per boomlings.dev.
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

	var deadline := Time.get_ticks_msec() + 30_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		push_warning("[RobTop] timed out after 25 seconds: %s" % url)
		return {"ok": false, "error": "RobTop did not respond within 25 seconds", "retryable": true}

	request.queue_free()
	var result: int = completed[0]
	var status: int = completed[1]
	var bytes: PackedByteArray = completed[3]
	print("[RobTop] result=%d HTTP=%d bytes=%d" % [result, status, bytes.size()])
	if result != HTTPRequest.RESULT_SUCCESS:
		var is_cors := OS.has_feature("web") and (result == HTTPRequest.RESULT_CANT_CONNECT or result == HTTPRequest.RESULT_CONNECTION_ERROR)
		if is_cors:
			return {
				"ok": false,
				"error": "RobTop connection blocked by browser CORS policy. Trying fallback proxy.",
				"retryable": true,
			}
		return {"ok": false, "error": "RobTop connection failed (result %d)" % result, "retryable": true}
	if status == 401 or status == 403:
		return {
			"ok": false,
			"error": "Server returned HTTP %d" % status,
			"status": status,
			"retryable": OS.has_feature("web"),
		}
	if status < 200 or status >= 300:
		return {
			"ok": false,
			"error": "RobTop server returned HTTP %d" % status,
			"status": status,
			"retryable": status in TRANSIENT_HTTP_STATUSES or (OS.has_feature("web") and status == 400),
		}
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


static func _extract_k4(text: String) -> String:
	var extracted := NativeCore.extract_level_data_string(text)
	if not extracted.is_empty():
		return extracted
	return _extract_k4_fallback(text)


static func _extract_k4_fallback(text: String) -> String:
	var clean := text.strip_edges()
	if clean.is_empty():
		return ""

	if clean.begins_with("<?xml") or clean.begins_with("<plist"):
		var doc := GMD.parse(clean)
		if doc != null and not doc.level_string.is_empty():
			return doc.level_string

	# 1. GDHistory / CCLocalLevels shorthand: k4 ~~<string>~~
	var tilde_idx := clean.find("k4 ~~")
	if tilde_idx == -1:
		tilde_idx = clean.find("k4~~")
	if tilde_idx != -1:
		var start := clean.find("~~", tilde_idx) + 2
		var finish := clean.find("~~", start)
		if finish != -1:
			var candidate := clean.substr(start, finish - start).strip_edges()
			if not candidate.is_empty():
				return candidate

	# 2. GDHistory / CCLocalLevels with single underscore: k4 _<string>_
	var under_idx := clean.find("k4 _")
	if under_idx != -1:
		var start := under_idx + 4
		var finish := clean.find("_", start)
		if finish != -1:
			var candidate := clean.substr(start, finish - start).strip_edges()
			if not candidate.is_empty():
				return candidate

	# 3. Standard plist XML: <key>k4</key> ... <string>...</string>
	var key_idx := clean.find("<key>k4</key>")
	if key_idx != -1:
		var str_start := clean.find("<string>", key_idx)
		if str_start != -1:
			str_start += 8
			var str_end := clean.find("</string>", str_start)
			if str_end != -1:
				return clean.substr(str_start, str_end - str_start).strip_edges()

	# 4. Short plist XML: <k>k4</k> ... <s>...</s>
	var k_pos := clean.find("<k>k4</k>")
	if k_pos == -1:
		k_pos = clean.find("<k>k4 </k>")
	if k_pos != -1:
		var s_start := clean.find("<s>", k_pos)
		if s_start != -1:
			var s_end := clean.find("</s>", s_start + 3)
			if s_end != -1:
				return clean.substr(s_start + 3, s_end - (s_start + 3)).strip_edges()

	# 5. RobTop database response format: key 4 in colon-separated pairs
	if clean.contains(":4:") or clean.begins_with("4:"):
		var parts := clean.split(":")
		for i in range(0, parts.size() - 1, 2):
			if parts[i].strip_edges() == "4":
				return parts[i + 1].strip_edges()

	# 6. Raw base64 compressed data:
	if clean.begins_with("H4sI") or clean.begins_with("eJ") or clean.begins_with("H4sIA"):
		return clean

	# 7. Plain uncompressed level string:
	if clean.contains(";1,") or clean.begins_with("kS") or clean.begins_with("kA"):
		return clean

	return ""


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
