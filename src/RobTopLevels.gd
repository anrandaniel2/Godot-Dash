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

# ---------------------------------------------------------------------------
# Browser (Web) transport
# ---------------------------------------------------------------------------
# A browser only hands a page a cross-origin response when the server opts in
# with `Access-Control-Allow-Origin`. RobTop's boomlings.com does not - it also
# answers 403 to any request carrying an `Origin` header, which a browser
# always sends on a cross-origin POST - and neither do the GDHistory archive
# (history.geometrydash.eu) nor the song CDNs. (Checked against gdbrowser.com,
# which does send `Access-Control-Allow-Origin: *`, as a control.) Firing those
# requests from a Web build can therefore only produce browser CORS errors
# followed by "TypeError: Failed to fetch" in the console.
#
# The Web build reaches those hosts only through a relay that performs the
# request server-side and answers with CORS headers. Configure it with the
# `network/cors_proxy` project setting (so an exported build ships with it) or
# with `Config.cors_proxy` (user config). tools/serve_web.py serves such a
# relay for local exports, and tools/web_relay_worker.js is a deployable
# Cloudflare Worker. Without a relay the Web build skips the request and says
# why instead of generating console errors.
const WEB_RELAY_SETTING := "network/cors_proxy"
const WEB_RELAY_REQUIRED := "Online downloads aren't available in this browser build (browsers block direct requests to RobTop's servers)."
const WEB_RELAY_HINT := "The desktop and Android builds download normally. Hosting this page? Deploy tools/web_relay_worker.js and set the \"network/cors_proxy\" project setting (or Config.cors_proxy) to enable downloads here."
# Hosts verified to answer with `Access-Control-Allow-Origin: *`, i.e. the only
# ones a Web build may call directly. GDBrowser's JSON API is what the online
# level list uses; everything else goes through the relay.
const WEB_CORS_HOSTS := ["gdbrowser.com"]


## The host part of an absolute URL, port stripped and lower-cased.
static func _host_of(url: String) -> String:
	var rest := url.trim_prefix("https://").trim_prefix("http://")
	var slash := rest.find("/")
	var authority := rest.substr(0, slash) if slash != -1 else rest
	return authority.get_slice(":", 0).to_lower()


## Whether this process can perform cross-origin GD requests at all.
## Desktop/mobile builds always can; a Web build needs a configured relay.
func downloads_available() -> bool:
	return not OS.has_feature("web") or not web_relay().is_empty()


## The relay prefix used for every cross-origin request on the Web build.
## An empty result means "no relay configured", and every Web request path
## then returns WEB_RELAY_REQUIRED instead of a browser-rejected fetch.
func web_relay() -> String:
	var relay := str(ProjectSettings.get_setting(WEB_RELAY_SETTING, "")).strip_edges()
	if relay.is_empty() and Config != null:
		relay = str(Config.cors_proxy).strip_edges()
	if relay.is_empty() and Config != null and Config.config_file != null:
		relay = str(Config.config_file.get_value("Internet", "cors_proxy", "")).strip_edges()
	if relay.is_empty() and _served_from_dev_server():
		# tools/serve_web.py exposes /cors-proxy, so a local export needs no setup.
		relay = "/cors-proxy?url="
	if not relay.is_empty() and not relay.contains("?"):
		# A bare relay origin ("https://relay.example.com") is accepted as well as
		# the documented "?url=" form: the Worker and tools/serve_web.py both read
		# the target from the `url` query parameter.
		relay = relay.trim_suffix("/") + "/?url="
	return relay


## Whether the page is being served by tools/serve_web.py, which binds 0.0.0.0
## and answers `/cors-proxy` on every interface. Loopback names and any plain
## http:// origin count: the hosted builds (itch.io, static hosting) are https
## and always need an explicitly configured relay.
func _served_from_dev_server() -> bool:
	if not OS.has_feature("web") or JavaScriptBridge == null:
		return false
	var host := str(JavaScriptBridge.eval("window.location.hostname")).strip_edges()
	if host == "localhost" or host == "127.0.0.1" or host == "[::1]" or host == "::1":
		return true
	return str(JavaScriptBridge.eval("window.location.protocol")).strip_edges() == "http:"


func search(query: String, page: int = 0, category: int = 1) -> Dictionary:
	if OS.has_feature("web"):
		var web_res := await _search_web(query, page, category)
		if web_res.ok:
			return web_res
		# GDBrowser answers with CORS headers; plain boomlings does not, so only
		# retry there when a relay can carry the POST.
		if web_relay().is_empty():
			return web_res
		push_warning("[RobTop] Web search fallback through relay: %s" % str(web_res.get("error", "")))

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
		# boomlings.com rejects browser POSTs (no CORS headers, plus a 403 on
		# the Origin header every browser attaches), so the Web build only goes
		# through the relay. Without one, explain the limitation instead of
		# firing a request the browser is guaranteed to reject.
		if web_relay().is_empty():
			return _error(WEB_RELAY_REQUIRED, WEB_RELAY_HINT)
		# A relay can carry the POST, so ask RobTop first (current version plus
		# song fields); the archive stays as the fallback.
		var direct_res := await _download_direct(level_id, summary)
		if direct_res.ok:
			return direct_res
		var gd_res := await _download_gdhistory(level_id, summary)
		if gd_res.ok:
			return gd_res
		return gd_res if not str(gd_res.get("error", "")).is_empty() else direct_res

	var direct_res := await _download_direct(level_id, summary)
	if direct_res.ok:
		return direct_res
	var gd_res := await _download_gdhistory(level_id, summary)
	if gd_res.ok:
		return gd_res
	return direct_res


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
	if not report.inert_trigger_ids.is_empty():
		print("[RobTop] inert triggers:\n%s" % report.inert_trigger_breakdown())
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





func _download_gdhistory(level_id: int, summary: Dictionary = {}) -> Dictionary:
	var info_url := "https://history.geometrydash.eu/api/v1/level/%d/" % level_id
	print("[RobTop] Level download via GDHistory: %s" % info_url)
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
	if OS.has_feature("web") and web_relay().is_empty():
		# Every song host is cross-origin and sends no CORS headers, so a
		# browser fetch can only fail. Report it instead of trying.
		return _error("Music downloads need a CORS relay in this browser build.")
	var file_name := "robtop_%d.mp3" % song_id
	var final_path := Constants.SONG_DIR + file_name
	if FileAccess.file_exists(final_path):
		var cached := FileAccess.open(final_path, FileAccess.READ)
		if cached != null and cached.get_length() > 0:
			return {"ok": true, "file_name": file_name}

	var candidates: PackedStringArray = []
	if not direct_url.is_empty():
		candidates.append(direct_url)

	# 1. BunnyCDN custom songs mirror (fast; served through the relay on Web).
	candidates.append("https://geometrydashcontent.b-cdn.net/songs/%d.mp3" % song_id)
	if song_id >= 10000000:
		candidates.append("https://geometrydashfiles.b-cdn.net/music/%d.mp3" % song_id)
		candidates.append("https://geometrydashfiles.b-cdn.net/music/%d.ogg" % song_id)
		candidates.append("https://cvolton.eu/music/%d.ogg" % song_id)

	# 2. Newgrounds direct download redirect
	candidates.append("https://www.newgrounds.com/audio/download/%d" % song_id)

	# 3. Fetch official RobTop song info via getGJSongInfo.php when the request
	# can reach it: desktop/mobile directly, Web through a relay that can carry
	# the POST. A browser on its own never can.
	if not OS.has_feature("web") or not web_relay().is_empty():
		var song_fields := {
			"gameVersion": "21",
			"binaryVersion": "35",
			"gdw": "0",
			"accountID": "0",
			"gjp": "",
			"uuid": "0",
			"songID": str(song_id),
			"secret": COMMON_SECRET,
		}
		var info := await _post(SONG_INFO_URL, song_fields)
		if not info.ok and bool(info.get("retryable", false)):
			info = await _post(SONG_INFO_FALLBACK_URL, song_fields)
		if info.ok and info.text != "-1" and info.text != "-2":
			var song_values := _pairs(info.text, "~|~")
			var robtop_url: String = song_values.get("10", "").uri_decode()
			if not robtop_url.is_empty() and not candidates.has(robtop_url):
				candidates.insert(0, robtop_url)

	DirAccess.make_dir_recursive_absolute(Constants.SONG_DIR)

	for cand in candidates:
		var media_url := cand.strip_edges()
		if media_url.begins_with("http://"):
			media_url = "https://" + media_url.trim_prefix("http://")
		if not media_url.begins_with("https://") and not media_url.begins_with("http://"):
			continue
		var downloaded := await _download_audio(media_url, final_path)
		if downloaded.ok:
			print("[RobTop] cached song %d: %s" % [song_id, file_name])
			return {"ok": true, "file_name": file_name}

	return _error("Music %d could not be downloaded." % song_id)


## Downloads and caches a Geometry Dash 2.2 SFX by ID.
func download_sfx(sfx_id: int) -> Dictionary:
	if sfx_id <= 0:
		return _error("Invalid SFX ID %d" % sfx_id)
	if not downloads_available():
		# Every SFX host is cross-origin without CORS headers; on Web this is a
		# relay-only download like music, so don't enter the candidate loop.
		return _error("Sound downloads need a CORS relay in this browser build.")

	var file_name := "sfx_%d.ogg" % sfx_id
	var final_path := Constants.SFX_DIR + file_name
	if FileAccess.file_exists(final_path):
		var cached := FileAccess.open(final_path, FileAccess.READ)
		if cached != null and cached.get_length() > 0:
			return {"ok": true, "file_name": file_name, "path": final_path}

	var candidates: PackedStringArray = [
		"https://geometrydashfiles.b-cdn.net/sfx/s%d.ogg" % sfx_id,
		"https://cvolton.eu/sfx/s%d.ogg" % sfx_id,
	]
	if sfx_id >= 10000000:
		candidates.append("https://geometrydashfiles.b-cdn.net/music/%d.ogg" % sfx_id)
		candidates.append("https://geometrydashfiles.b-cdn.net/music/%d.mp3" % sfx_id)
		candidates.append("https://cvolton.eu/music/%d.ogg" % sfx_id)

	DirAccess.make_dir_recursive_absolute(Constants.SFX_DIR)

	for cand in candidates:
		var downloaded := await _download_audio(cand, final_path)
		if downloaded.ok:
			print("[RobTop] cached SFX %d: %s" % [sfx_id, file_name])
			return {"ok": true, "file_name": file_name, "path": final_path}

	return _error("SFX %d could not be downloaded." % sfx_id)


func _download_audio(url: String, destination: String) -> Dictionary:
	if OS.has_feature("web"):
		# The song hosts (the b-cdn mirrors and Newgrounds) also send no CORS
		# headers, so a direct browser fetch can only produce a console CORS
		# error. Go through the relay, or refuse before making the request.
		var relay := web_relay()
		if relay.is_empty():
			return _error("Audio downloads need a CORS relay in this browser build.")
		return await _download_audio_once(_resolve_url(url, relay), destination)
	return await _download_audio_once(url, destination)


static func _resolve_url(endpoint: String, proxy_prefix: String = "") -> String:
	return NativeCore.resolve_proxy_url(endpoint, proxy_prefix)


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
	if OS.has_feature("web"):
		# CORS-enabled front-ends (GDBrowser) are readable directly; every other
		# host must go through the relay. history.geometrydash.eu answers with no
		# Access-Control-Allow-Origin at all, so a direct browser GET is always
		# rejected there - relay it, or don't try.
		if WEB_CORS_HOSTS.has(_host_of(url)):
			return await _get_text_once(url)
		var relay := web_relay()
		if relay.is_empty():
			return _error(WEB_RELAY_REQUIRED, WEB_RELAY_HINT)
		var res := await _get_text_once(_resolve_url(url, relay))
		if res.ok and res.has("text"):
			# Relays built on allorigins' "/get" style wrap the body in a JSON
			# envelope; the raw form is the common case.
			var raw_text: String = str(res["text"]).strip_edges()
			if raw_text.begins_with("{\"contents\":"):
				var parsed_wrap: Variant = JSON.parse_string(raw_text)
				if parsed_wrap is Dictionary and parsed_wrap.has("contents"):
					res["text"] = str(parsed_wrap["contents"]).strip_edges()
		return res
	return await _get_text_once(url)


func _get_text_once(target_url: String) -> Dictionary:
	print("[RobTop] GET %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 15.0
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
		var is_cors := NativeCore.is_cors_error(result, status, OS.has_feature("web"))
		if is_cors:
			return {"ok": false, "error": "Request blocked by browser CORS policy", "retryable": true}
		return {"ok": false, "error": "Request failed (result %d)" % result, "retryable": true}
	if status < 200 or status >= 300:
		return {"ok": false, "error": "Server returned HTTP %d" % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	return {"ok": true, "text": bytes.get_string_from_utf8().strip_edges()}


func _download_audio_once(target_url: String, destination: String) -> Dictionary:
	print("[RobTop] GET audio from %s" % target_url)
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 30.0
	request.max_redirects = 5
	request.body_size_limit = MAX_SONG_BYTES
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(func(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		completed.assign([result, status, body])
	)
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("Accept: audio/*, */*")
		headers.append("User-Agent: Godot-Dash/1")
	var error := request.request(target_url, headers)
	if error != OK:
		request.queue_free()
		return _error("Could not start the audio download (error %d)." % error)
	var deadline := Time.get_ticks_msec() + 30_000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if completed.is_empty():
		request.cancel_request()
		request.queue_free()
		return {"ok": false, "error": "Audio download timed out after 30 seconds.", "retryable": true}
	request.queue_free()
	var result := int(completed[0])
	var status := int(completed[1])
	var body: PackedByteArray = completed[2]
	if result != HTTPRequest.RESULT_SUCCESS:
		var is_cors := NativeCore.is_cors_error(result, status, OS.has_feature("web"))
		if is_cors:
			return {"ok": false, "error": "Audio download blocked by browser CORS policy.", "retryable": false}
		return {"ok": false, "error": "Audio download failed (result %d)." % result, "retryable": true}
	if status < 200 or status >= 300:
		return {"ok": false, "error": "Audio host returned HTTP %d." % status, "status": status, "retryable": status in TRANSIENT_HTTP_STATUSES}
	if body.size() < 1000 or body.size() > MAX_SONG_BYTES:
		return _error("Audio download returned an empty or oversized audio file (%d bytes)." % body.size())
	if not NativeCore.is_audio_stream(body):
		return _error("Audio download returned invalid audio data.")

	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	var file := FileAccess.open(destination, FileAccess.WRITE)
	if file == null:
		return _error("Could not save audio to %s (error %d)." % [destination, FileAccess.get_open_error()])
	file.store_buffer(body)
	file.close()
	print("[RobTop] Saved audio to %s (%d bytes)" % [destination, body.size()])
	return {"ok": true}


static func _looks_like_audio(bytes: PackedByteArray, extension: String = "") -> bool:
	return NativeCore.is_audio_stream(bytes, extension)


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
	if OS.has_feature("web"):
		# A browser POST to boomlings.com gets an Origin header it refuses and a
		# response without CORS headers; the relay is the only way through.
		var relay := web_relay()
		if relay.is_empty():
			return _error(WEB_RELAY_REQUIRED, WEB_RELAY_HINT)
		return await _post_once(url, fields, relay)
	return await _post_once(url, fields, "")


func _post_once(url: String, fields: Dictionary, proxy_override: String = "") -> Dictionary:
	var target_url := _resolve_url(url, proxy_override)
	print("[RobTop] POST %s" % target_url)
	var request := HTTPRequest.new()
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


static func _error(message: String, hint: String = "") -> Dictionary:
	var result := {"ok": false, "error": message}
	if not hint.is_empty():
		result["hint"] = hint
	return result
