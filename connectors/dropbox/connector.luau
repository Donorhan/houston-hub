-- Dropbox API v2. Arguments and results keep Dropbox's native field names.
type Options = {[string]: any}
type Endpoint = {route: string, scope: string, access: string?, required: {[string]: string}?, style: ("download" | "upload")?, void: boolean?, emptyResult: boolean?, help: string, inputSchema: Options}
local API = "https://api.dropboxapi.com/2/"
local CONTENT = "https://content.dropboxapi.com/2/"
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_UPLOAD_BYTES = 150 * 1024 * 1024 -- Dropbox's limit for one upload request.

local function text(value: any, field: string): string
	assert(type(value) == "string" and value ~= "", field .. " must be a nonempty string")
	return value
end

local function options(endpoint: Endpoint, value: any): Options
	if value == nil then value = {} end
	assert(type(value) == "table", "opts must be an object")
	for key in value do assert(type(key) == "string", "opts must have named fields") end
	if endpoint.void then assert(next(value) == nil, "this operation takes no options") end
	if endpoint.required then
		for field, kind in endpoint.required do
			local actual = type(value[field])
			local valid = if kind == "union" then actual == "string" or actual == "table"
				elseif kind == "array" or kind == "struct" then actual == "table" else actual == kind
			assert(valid, field .. " must be a " .. kind)
		end
	end
	return table.clone(value)
end

-- Dropbox-API-Arg must be HTTP header safe: escape DEL and every non-ASCII character.
local function headerJSON(value: Options): string
	return (string.gsub(json.encode(value), "[\127-\244][\128-\191]*", function(char: string): string
		local code = utf8.codepoint(char)
		if code < 0x10000 then return string.format("\\u%04x", code) end
		code -= 0x10000
		return string.format("\\u%04x\\u%04x", 0xD800 + code // 0x400, 0xDC00 + code % 0x400)
	end))
end

local function fail(operation: string, response: HttpResponse): never
	local raw = await(response.body:readPrefix(4096))
	-- Route errors are JSON with an error_summary such as "path/not_found/.."; bad input is plain text.
	local ok, decoded = pcall(json.decode, raw)
	local problem = if ok and type(decoded) == "table" then decoded else {}
	local summary = if type(problem.error_summary) == "string" then problem.error_summary else raw
	local message = "Dropbox HTTP " .. tostring(response.statusCode)
	if summary ~= "" then message ..= ": " .. string.sub(summary, 1, 600) end
	local user = problem.user_message
	if type(user) == "table" and type(user.text) == "string" then message ..= " (" .. string.sub(user.text, 1, 300) .. ")" end
	local retry = response.headers["retry-after"]
	if retry and retry[1] then message ..= "; Retry-After: " .. retry[1] end
	-- Dropbox asks callers to retry when concurrent writes to one namespace collide.
	local contended = string.find(summary, "too_many_write_operations", 1, true) ~= nil
	return houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode,
		retryable = response.statusCode == 429 or response.statusCode >= 500 or contended, message = message})
end

local function invalid(operation: string, response: HttpResponse, message: string): never
	return houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode, retryable = false, message = message})
end

-- Returns the JSON object or array Dropbox sent, or {success=true} for routes whose result is null.
local function decode(operation: string, endpoint: Endpoint, response: HttpResponse): any
	if response.statusCode < 200 or response.statusCode >= 300 then fail(operation, response) end
	local raw = await(response.body:readAll())
	if endpoint.emptyResult and string.match(raw, "^%s*null%s*$") then return {success = true} end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" then invalid(operation, response, "Dropbox returned invalid JSON") end
	return value
end

local function rpc(name: string, endpoint: Endpoint, input: any): any
	local args = options(endpoint, input)
	return decode(name, endpoint, await(http.request({method = "POST", url = API .. endpoint.route,
		headers = if endpoint.void then nil else {["Content-Type"] = {"application/json"}},
		body = if endpoint.void then nil else json.encode(args)})))
end

-- Content routes take a session file path beside Dropbox's argument, which travels in a header.
local function content(endpoint: Endpoint, input: any, headers: HttpHeaders): (HttpRequest, string)
	local args = options(endpoint, input)
	local path = text(args.session_path, "session_path")
	args.session_path = nil
	headers["Dropbox-API-Arg"] = {headerJSON(args)}
	return {method = "POST", url = CONTENT .. endpoint.route, headers = headers}, path
end

-- Discards the destination, keeping any previous file, and waits until the path can be opened again.
local function discard(output: any)
	output:cancel()
	pcall(function() await(output:close()) end)
end

-- Streams the response body to a session file; Dropbox describes it in the Dropbox-API-Result header.
local function download(name: string, endpoint: Endpoint, input: any, guard: ((any) -> any)?): Options
	local request, path = content(endpoint, input, {})
	-- Opening the session file first refuses an invalid path before any Dropbox request.
	local output = fs.open(path, "w")
	local opened, response = pcall(function(): HttpResponse
		await(output)
		return await(http.request(request))
	end)
	if not opened then
		discard(output)
		error(response, 0)
	end
	if response.statusCode < 200 or response.statusCode >= 300 then
		discard(output)
		fail(name, response)
	end
	local header = response.headers["dropbox-api-result"]
	local ok, result = pcall(json.decode, if header and header[1] then header[1] else "")
	if not ok or type(result) ~= "table" then
		response.body:close()
		discard(output)
		invalid(name, response, "Dropbox returned no Dropbox-API-Result metadata")
	end
	if guard then
		local allowed, problem = pcall(guard, result)
		if not allowed then
			response.body:close()
			discard(output)
			error(problem, 0)
		end
	end
	output:write(response.body)
	await(output:close())
	return {session_path = path, url = await(fs.signedGetUrl(path)), size = await(fs.stat(path)).size, result = result}
end

local function upload(name: string, endpoint: Endpoint, input: any): any
	local request, path = content(endpoint, input, {["Content-Type"] = {"application/octet-stream"}})
	local file = await(fs.stat(path))
	assert(file.isFile, "session_path must be a file")
	assert(file.size <= MAX_UPLOAD_BYTES, "upload sends at most 150 MiB; larger files are not supported")
	request.body = fs.open(path, "r")
	return decode(name, endpoint, await(http.request(request)))
end

-- Shared JSON Schema shapes. Dropbox unions accept a tag string when the variant has no payload.
local STRING = {type = "string"}
local NONEMPTY = {type = "string", minLength = 1}
local FALSE = {type = "boolean", default = false}
local TRUE = {type = "boolean", default = true}
local PATH = {type = "string", description = "Dropbox path or supported id:/rev:/ns: identifier; see paths."}
local ROOT_PATH = {type = "string", description = "Folder path or ID; use an empty string for the root. See paths."}
local SESSION_PATH = {type = "string", minLength = 1, description = "Relative Houston session file path; see transfers."}
local REV = {type = "string", pattern = "^[0-9a-f]+$", description = "Dropbox revision from file metadata."}
local TIMESTAMP = {type = "string", format = "date-time", description = "UTC timestamp, for example 2026-01-15T12:00:00Z."}
local CURSOR_SCHEMA = {type = "string", minLength = 1, description = "Opaque cursor from the preceding page; keep it intact. See pagination."}
local function object(properties: Options, required: {string}?): Options
	return {type = "object", properties = properties, required = required or json.decode("[]"), additionalProperties = true}
end
local function list(items: Options, minimum: number?, maximum: number?): Options
	return {type = "array", items = items, minItems = minimum, maxItems = maximum}
end
local function limit(maximum: number, default: number?): Options
	return {type = "integer", minimum = 1, maximum = maximum, default = default}
end
local function tags(values: {string}, default: string?): Options
	return {oneOf = {{type = "string", enum = values}, object({[".tag"] = {type = "string", enum = values}}, {".tag"})}, default = default}
end
local function variant(tag: string, fields: Options, required: {string}?): Options
	local properties = table.clone(fields)
	properties[".tag"] = {const = tag}
	local keys = table.clone(required or {})
	table.insert(keys, ".tag")
	return object(properties, keys)
end
local MEMBER = {oneOf = {
	variant("email", {email = {type = "string", format = "email"}}, {"email"}),
	variant("dropbox_id", {dropbox_id = NONEMPTY}, {"dropbox_id"}),
}}
local ACCESS = tags({"editor", "viewer", "viewer_no_comment"})
local AUDIENCE = tags({"public", "team", "no_one"})
local LINK_SETTINGS = object({require_password = {type = "boolean"}, link_password = STRING, expires = TIMESTAMP,
	audience = AUDIENCE, access = tags({"viewer", "editor", "max"}),
	requested_visibility = tags({"public", "team_only", "password"}), allow_download = {type = "boolean"}})
local DEADLINE = object({deadline = TIMESTAMP, allow_late_uploads = tags({"one_day", "two_days", "seven_days", "thirty_days", "always"})}, {"deadline"})
local PROPERTY_FILTER = variant("filter_some", {filter_some = list(NONEMPTY, 1)}, {"filter_some"})
local PROPERTY_GROUPS = list(object({template_id = NONEMPTY,
	fields = list(object({name = STRING, value = STRING}, {"name", "value"}))}, {"template_id", "fields"}))
local FILE_ACTIONS = list(tags({"disable_viewer_info", "edit_contents", "enable_viewer_info", "invite_viewer", "invite_viewer_no_comment", "invite_editor", "unshare", "relinquish_membership", "share_link", "create_link", "create_view_link", "create_edit_link"}))
local FOLDER_ACTIONS = list(tags({"change_options", "disable_viewer_info", "edit_contents", "enable_viewer_info", "invite_editor", "invite_viewer", "invite_viewer_no_comment", "relinquish_membership", "unmount", "unshare", "leave_a_copy", "share_link", "create_link", "create_view_link", "create_edit_link", "set_access_inheritance"}))
local MEMBER_ACTIONS = list(tags({"leave_a_copy", "make_editor", "make_owner", "make_viewer", "make_viewer_no_comment", "remove"}))
local RELOCATION = object({from_path = PATH, to_path = PATH}, {"from_path", "to_path"})
local SEARCH_OPTIONS = object({path = ROOT_PATH, max_results = limit(1000, 100), order_by = tags({"relevance", "last_modified_time"}),
	file_status = tags({"active", "deleted"}, "active"), filename_only = FALSE, file_extensions = list(STRING),
	file_categories = list(tags({"image", "document", "pdf", "spreadsheet", "presentation", "audio", "video", "folder", "paper", "others"})), account_id = NONEMPTY})
local FOLDER_OPTIONS = {path = ROOT_PATH, recursive = FALSE, include_media_info = FALSE, include_deleted = FALSE,
	include_has_explicit_shared_members = FALSE, include_mounted_folders = TRUE, limit = limit(2000),
	shared_link = object({url = NONEMPTY, password = STRING}, {"url"}), include_property_groups = PROPERTY_FILTER,
	include_non_downloadable_files = TRUE, include_restorable_info = FALSE}
local function schema(properties: Options, example: Options): Options
	local result = object(properties)
	result.examples = {example}
	return result
end

local ENTRIES = " complete.entries holds one result per entry."
local function job(starters: string, tags: string?): string
	return "Returns {['.tag']=" .. (tags or "'in_progress'|'complete'|'failed'") .. ", ...}. Polls " .. starters .. "."
end
local endpoints: {[string]: Endpoint} = {
	-- Account
	getCurrentAccount = {inputSchema = schema({}, {}),
		route = "users/get_current_account", scope = "account_info.read", void = true,
		help = "Returns {account_id, name, email, root_info, ...}. root_info identifies the account's home and root namespaces."},
	getSpaceUsage = {inputSchema = schema({}, {}),
		route = "users/get_space_usage", scope = "account_info.read", void = true, help = "Returns {used, allocation}. Bytes used and the quota."},
	getAccount = {inputSchema = schema({account_id = NONEMPTY}, {account_id = "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"}),
		route = "users/get_account", scope = "sharing.read", required = {account_id = "string"}, access = "sharing:read", help = "Returns {account_id, name, email, ...}. Another Dropbox user, e.g. a folder member."},

	-- Files and folders
	getMetadata = {inputSchema = schema({path = PATH, include_media_info = FALSE, include_deleted = FALSE, include_has_explicit_shared_members = FALSE, include_property_groups = PROPERTY_FILTER}, {path = "/Reports/report.pdf"}),
		route = "files/get_metadata", scope = "files.metadata.read", required = {path = "string"}, access = "files:read",
		help = "Returns file, folder or deleted metadata; ['.tag'] tells which."},
	listFolder = {inputSchema = schema(FOLDER_OPTIONS, {path = "/Reports", recursive = false, limit = 100}),
		route = "files/list_folder", scope = "files.metadata.read", required = {path = "string"}, access = "files:read",
		help = "List one page of files and folders. Returns {entries, cursor, has_more}; entries use ['.tag']='file'|'folder'|'deleted'. Continue with listFolderContinue while has_more is true. path='' is the root. limit is a hint up to 2000; recursive traversal can be expensive. include_media_info is deprecated and has no effect on listing."},
	listFolderContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "files/list_folder/continue", scope = "files.metadata.read", required = {cursor = "string"}, access = "files:read", help = "Returns {entries, cursor, has_more}. Continues listFolder, or returns changes after listFolderGetLatestCursor; save the latest cursor and continue while has_more is true."},
	listFolderGetLatestCursor = {inputSchema = schema(FOLDER_OPTIONS, {path = "/Reports", recursive = false, limit = 100}),
		route = "files/list_folder/get_latest_cursor", scope = "files.metadata.read", required = {path = "string"}, access = "files:read",
		help = "Returns {cursor}. A cursor at the current state; listFolderContinue on it later returns only changes."},
	search = {inputSchema = schema({query = {type = "string", maxLength = 1000}, options = SEARCH_OPTIONS, match_field_options = object({include_highlights = FALSE}), include_highlights = {type = "boolean"}}, {query = "report", options = {path = "/Reports", max_results = 20}}),
		route = "files/search_v2", scope = "files.metadata.read", required = {query = "string"}, access = "files:read",
		help = "Returns {matches, has_more, cursor?}. Matches names and content; matches[i].metadata.metadata is the file."},
	searchContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "files/search/continue_v2", scope = "files.metadata.read", required = {cursor = "string"}, access = "files:read", help = "Returns {matches, has_more, cursor?}. Continues search using its opaque cursor; matches[i].metadata.metadata contains the file. Up to 10,000 matches across pages; indexing can lag and results may repeat or be omitted."},
	listRevisions = {inputSchema = schema({path = PATH, mode = tags({"path", "id"}, "path"), limit = limit(100, 10), before_rev = REV, include_restorable_info = FALSE}, {path = "/Reports/report.pdf", limit = 10}),
		route = "files/list_revisions", scope = "files.metadata.read", required = {path = "string"}, access = "files:read", help = "Returns {is_deleted, entries, has_more}. A file's versions, newest first; pass the last entry's rev as before_rev for older ones."},
	getTemporaryLink = {inputSchema = schema({path = PATH}, {path = "/Reports/report.pdf"}),
		route = "files/get_temporary_link", scope = "files.content.read", required = {path = "string"}, access = "files:read",
		help = "Returns {metadata, link}. A direct download link valid for four hours, to hand to a person or an outside client; Houston scripts transfer files with download."},
	download = {inputSchema = schema({path = PATH, rev = REV, session_path = SESSION_PATH}, {path = "/Reports/report.pdf", session_path = "downloads/report.pdf"}),
		route = "files/download", scope = "files.content.read", required = {path = "string"}, access = "files:read", style = "download", help = "Returns {session_path, url, size, result=file metadata}."},
	downloadZip = {inputSchema = schema({path = PATH, session_path = SESSION_PATH}, {path = "/Reports", session_path = "downloads/reports.zip"}),
		route = "files/download_zip", scope = "files.content.read", required = {path = "string"}, access = "files:read", style = "download",
		help = "Returns {session_path, url, size, result={metadata}}. A folder as a zip: Dropbox requires under 20 GB total, under 4 GB per file and fewer than 10,000 files/folders including the root. Houston's smaller transfer limit still applies."},
	export = {inputSchema = schema({path = PATH, export_format = STRING, session_path = SESSION_PATH}, {path = "/Reports/Notes.paper", export_format = "markdown", session_path = "downloads/notes.md"}),
		route = "files/export", scope = "files.content.read", required = {path = "string"}, access = "files:read", style = "download",
		help = "Returns {session_path, url, size, result={export_metadata, file_metadata}}. Converts files that have no downloadable bytes, such as Paper docs: their metadata has export_info.export_as, and export_info.export_options lists other export_format values."},
	getPreview = {inputSchema = schema({path = PATH, rev = REV, session_path = SESSION_PATH}, {path = "/Reports/report.pdf", session_path = "downloads/report.pdf"}),
		route = "files/get_preview", scope = "files.content.read", required = {path = "string"}, access = "files:read", style = "download",
		help = "Returns {session_path, url, size, result=file metadata}. A PDF preview of documents or an HTML preview of spreadsheets."},
	getThumbnail = {inputSchema = schema({path = PATH, format = tags({"jpeg", "png", "webp"}, "jpeg"), size = tags({"w32h32", "w64h64", "w128h128", "w256h256", "w480h320", "w640h480", "w960h640", "w1024h768", "w2048h1536"}, "w64h64"), mode = tags({"strict", "bestfit", "fitone_bestfit"}, "strict"), exclude_media_info = {type = "boolean"}, session_path = SESSION_PATH}, {path = "/Reports/photo.jpg", format = "png", size = "w256h256", session_path = "downloads/thumbnail.png"}),
		route = "files/get_thumbnail", scope = "files.content.read", required = {path = "string"}, access = "files:read", style = "download",
		help = "Returns {session_path, url, size, result=file metadata}. Images only; defaults to a 64x64 JPEG."},
	createFolder = {inputSchema = schema({path = PATH, autorename = FALSE}, {path = "/Reports/New folder"}),
		route = "files/create_folder_v2", scope = "files.content.write", required = {path = "string"}, access = "files:write", help = "Create one folder. Returns {metadata} with its name, ID and canonical paths. Existing destinations fail unless autorename=true is available and requested; inspect the returned path."},
	upload = {inputSchema = schema({path = PATH, session_path = SESSION_PATH, mode = {oneOf = {tags({"add", "overwrite"}), variant("update", {update = REV}, {"update"})}, default = "add"}, autorename = FALSE, client_modified = TIMESTAMP, mute = FALSE, property_groups = PROPERTY_GROUPS, strict_conflict = FALSE, content_hash = {type = "string", pattern = "^[0-9a-f]{64}$"}}, {path = "/Reports/upload.txt", session_path = "upload.txt", mode = "add"}),
		route = "files/upload", scope = "files.content.write", required = {path = "string"}, access = "files:write", style = "upload",
		help = "Upload an existing session file. Returns file metadata including id, name, size, rev and canonical paths. Sends at most 150 MiB. mode defaults to add; overwrite replaces the destination, while update requires its revision. autorename resolves conflicts with a different name; inspect the returned path. mute suppresses client notifications; strict_conflict rejects revision mismatches even for deleted or identical files. content_hash uses Dropbox's block hash algorithm, not an ordinary whole-file SHA-256."},
	saveUrl = {inputSchema = schema({path = PATH, url = {type = "string", format = "uri"}}, {path = "/Reports/report.pdf", url = "https://example.com/report.pdf"}),
		route = "files/save_url", scope = "files.content.write", required = {path = "string", url = "string"}, access = "files:write",
		help = "Returns {['.tag']='async_job_id'|'complete', ...}. Dropbox downloads a public URL into path within 15 minutes; poll saveUrlCheckJobStatus."},
	saveUrlCheckJobStatus = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "files/save_url/check_job_status", scope = "files.content.write", required = {async_job_id = "string"}, access = "files:write", help = job("saveUrl")},
	move = {inputSchema = schema({from_path = PATH, to_path = PATH, autorename = FALSE, allow_shared_folder = FALSE, allow_ownership_transfer = FALSE}, {from_path = "/Reports/report.pdf", to_path = "/Reports/renamed.pdf"}),
		route = "files/move_v2", scope = "files.content.write", required = {from_path = "string", to_path = "string"}, access = "files:write", help = "Returns {metadata}. Moves or renames a file or folder."},
	copy = {inputSchema = schema({from_path = PATH, to_path = PATH, autorename = FALSE, allow_shared_folder = FALSE, allow_ownership_transfer = FALSE}, {from_path = "/Reports/report.pdf", to_path = "/Reports/renamed.pdf"}),
		route = "files/copy_v2", scope = "files.content.write", required = {from_path = "string", to_path = "string"}, access = "files:write", help = "Returns {metadata}."},
	delete = {inputSchema = schema({path = PATH, parent_rev = REV}, {path = "/Reports/old.pdf"}),
		route = "files/delete_v2", scope = "files.content.write", required = {path = "string"}, access = "files:write",
		help = "Returns {metadata}. Deleted files stay recoverable with restore for the account's retention period."},
	restore = {inputSchema = schema({path = PATH, rev = REV}, {path = "/Reports/report.pdf", rev = "a1c10ce0dd78"}),
		route = "files/restore", scope = "files.content.write", required = {path = "string", rev = "string"}, access = "files:write", help = "Returns file metadata. Restores a deleted file or an earlier revision from listRevisions."},
	moveBatch = {inputSchema = schema({entries = list(RELOCATION, 1, 1000), autorename = FALSE, allow_ownership_transfer = FALSE}, {entries = {{from_path = "/Reports/report.pdf", to_path = "/Archive/report.pdf"}}}),
		route = "files/move_batch_v2", scope = "files.content.write", required = {entries = "array"}, access = "files:write",
		help = "Returns {['.tag']='async_job_id'|'complete', ...}. Up to 1,000 entries; poll moveBatchCheck."},
	moveBatchCheck = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "files/move_batch/check_v2", scope = "files.content.write", required = {async_job_id = "string"}, access = "files:write", help = job("moveBatch", "'in_progress'|'complete'") .. ENTRIES},
	copyBatch = {inputSchema = schema({entries = list(RELOCATION, 1, 1000), autorename = FALSE}, {entries = {{from_path = "/Reports/report.pdf", to_path = "/Archive/report.pdf"}}}),
		route = "files/copy_batch_v2", scope = "files.content.write", required = {entries = "array"}, access = "files:write",
		help = "Returns {['.tag']='async_job_id'|'complete', ...}. Up to 1,000 entries; poll copyBatchCheck."},
	copyBatchCheck = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "files/copy_batch/check_v2", scope = "files.content.write", required = {async_job_id = "string"}, access = "files:write", help = job("copyBatch", "'in_progress'|'complete'") .. ENTRIES},
	deleteBatch = {inputSchema = schema({entries = list(object({path = PATH, parent_rev = REV}, {"path"}), 0, 1000)}, {entries = {{path = "/Reports/old.pdf"}}}),
		route = "files/delete_batch", scope = "files.content.write", required = {entries = "array"}, access = "files:write",
		help = "Returns {['.tag']='async_job_id'|'complete', ...}. Up to 1,000 entries; poll deleteBatchCheck."},
	deleteBatchCheck = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "files/delete_batch/check", scope = "files.content.write", required = {async_job_id = "string"}, access = "files:write", help = job("deleteBatch") .. ENTRIES},

	-- Shared links
	listSharedLinks = {inputSchema = schema({path = PATH, cursor = CURSOR_SCHEMA, direct_only = {type = "boolean"}}, {path = "/Reports/report.pdf", direct_only = true}),
		route = "sharing/list_shared_links", scope = "sharing.read", access = "sharing:read",
		help = "Returns {links, has_more, cursor?}. Without path, every link the account created; pass cursor back for the next page."},
	getSharedLinkMetadata = {inputSchema = schema({url = NONEMPTY, path = STRING, link_password = STRING}, {url = "https://www.dropbox.com/s/example/report.pdf?dl=0"}),
		route = "sharing/get_shared_link_metadata", scope = "sharing.read", required = {url = "string"}, access = "sharing:read", help = "Returns link metadata. path selects an item inside a shared folder link."},
	getSharedLinkFile = {inputSchema = schema({url = NONEMPTY, path = STRING, link_password = STRING, session_path = SESSION_PATH}, {url = "https://www.dropbox.com/s/example/report.pdf?dl=0", session_path = "downloads/shared.pdf"}),
		route = "sharing/get_shared_link_file", scope = "sharing.read", required = {url = "string"}, access = "sharing:read", style = "download",
		help = "Returns {session_path, url, size, result=link metadata}. Downloads a file behind a shared link, including links from other accounts."},
	createSharedLinkWithSettings = {inputSchema = schema({path = PATH, settings = LINK_SETTINGS}, {path = "/Reports/report.pdf", settings = {audience = "public", access = "viewer"}}),
		route = "sharing/create_shared_link_with_settings", scope = "sharing.write", required = {path = "string"}, access = "sharing:write",
		help = "Returns link metadata. Fails with shared_link_already_exists when a link exists; use listSharedLinks({path, direct_only=true})."},
	modifySharedLinkSettings = {inputSchema = schema({url = NONEMPTY, settings = LINK_SETTINGS, remove_expiration = FALSE}, {url = "https://www.dropbox.com/s/example/report.pdf?dl=0", settings = {allow_download = false}}),
		route = "sharing/modify_shared_link_settings", scope = "sharing.write", required = {url = "string", settings = "struct"}, access = "sharing:write", help = "Returns link metadata."},
	revokeSharedLink = {inputSchema = schema({url = NONEMPTY}, {url = "https://www.dropbox.com/s/example/report.pdf?dl=0"}),
		route = "sharing/revoke_shared_link", scope = "sharing.write", required = {url = "string"}, access = "sharing:write", emptyResult = true, help = "Returns {success=true}."},

	-- Shared folders
	listSharedFolders = {inputSchema = schema({limit = limit(1000, 1000), actions = FOLDER_ACTIONS}, {limit = 100}),
		route = "sharing/list_folders", scope = "sharing.read", access = "sharing:read", help = "Returns {entries, cursor?}. Shared folders the account has joined."},
	listSharedFoldersContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "sharing/list_folders/continue", scope = "sharing.read", required = {cursor = "string"}, access = "sharing:read", help = "Returns {entries, cursor?}. Continues listSharedFolders while a cursor is present."},
	listMountableFolders = {inputSchema = schema({limit = limit(1000, 1000), actions = FOLDER_ACTIONS}, {limit = 100}),
		route = "sharing/list_mountable_folders", scope = "sharing.read", access = "sharing:read", help = "Returns {entries, cursor?}. Shared folders the account can add to its Dropbox."},
	listMountableFoldersContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "sharing/list_mountable_folders/continue", scope = "sharing.read", required = {cursor = "string"}, access = "sharing:read", help = "Returns {entries, cursor?}. Continues listMountableFolders while a cursor is present."},
	getSharedFolderMetadata = {inputSchema = schema({shared_folder_id = NONEMPTY, actions = FOLDER_ACTIONS}, {shared_folder_id = "84528192421"}),
		route = "sharing/get_folder_metadata", scope = "sharing.read", required = {shared_folder_id = "string"}, access = "sharing:read",
		help = "Returns shared folder metadata. The ID is a folder's shared_folder_id or sharing_info.shared_folder_id."},
	listFolderMembers = {inputSchema = schema({shared_folder_id = NONEMPTY, path = STRING, actions = MEMBER_ACTIONS, limit = limit(1000, 1000)}, {shared_folder_id = "84528192421", limit = 100}),
		route = "sharing/list_folder_members", scope = "sharing.read", required = {shared_folder_id = "string"}, access = "sharing:read", help = "Returns {users, groups, invitees, cursor?}."},
	listFolderMembersContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "sharing/list_folder_members/continue", scope = "sharing.read", required = {cursor = "string"}, access = "sharing:read", help = "Returns {users, groups, invitees, cursor?}. Continues listFolderMembers while a cursor is present."},
	shareFolder = {inputSchema = schema({path = PATH, member_policy = tags({"team", "anyone"}), acl_update_policy = tags({"owner", "editors"}), shared_link_policy = tags({"anyone", "members"}), force_async = FALSE, viewer_info_policy = tags({"enabled", "disabled"}), access_inheritance = tags({"inherit", "no_inherit"}, "inherit"), actions = FOLDER_ACTIONS, link_settings = object({access_level = tags({"viewer", "viewer_no_comment"}), audience = AUDIENCE, expiry = {oneOf = {tags({"remove_expiry"}), variant("set_expiry", {set_expiry = TIMESTAMP}, {"set_expiry"})}}, password = {oneOf = {tags({"remove_password"}), variant("set_password", {set_password = STRING}, {"set_password"})}}})}, {path = "/Reports", force_async = true}),
		route = "sharing/share_folder", scope = "sharing.write", required = {path = "string"}, access = "sharing:write",
		help = "Returns {['.tag']='complete', ...} or {['.tag']='async_job_id', ...}; poll checkShareJobStatus."},
	checkShareJobStatus = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "sharing/check_share_job_status", scope = "sharing.write", required = {async_job_id = "string"}, access = "sharing:write", help = job("shareFolder")},
	addFolderMember = {inputSchema = schema({shared_folder_id = NONEMPTY, members = list(object({member = MEMBER, access_level = ACCESS}, {"member"})), quiet = FALSE, custom_message = NONEMPTY}, {shared_folder_id = "84528192421", members = {{member = {[".tag"] = "email", email = "ada@example.com"}, access_level = "viewer"}}, quiet = true}),
		route = "sharing/add_folder_member", scope = "sharing.write", required = {shared_folder_id = "string", members = "array"}, access = "sharing:write", emptyResult = true,
		help = "Returns {success=true}. Dropbox emails new members unless quiet=true."},
	updateFolderMember = {inputSchema = schema({shared_folder_id = NONEMPTY, member = variant("dropbox_id", {dropbox_id = NONEMPTY}, {"dropbox_id"}), access_level = ACCESS}, {shared_folder_id = "84528192421", member = {[".tag"] = "dropbox_id", dropbox_id = "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"}, access_level = "viewer"}),
		route = "sharing/update_folder_member", scope = "sharing.write", required = {shared_folder_id = "string", member = "union", access_level = "union"}, access = "sharing:write",
		help = "Returns member result. This route requires a Dropbox account ID, not an email selector."},
	removeFolderMember = {inputSchema = schema({shared_folder_id = NONEMPTY, member = MEMBER, leave_a_copy = {type = "boolean"}}, {shared_folder_id = "84528192421", member = {[".tag"] = "email", email = "ada@example.com"}, leave_a_copy = false}),
		route = "sharing/remove_folder_member", scope = "sharing.write", required = {shared_folder_id = "string", member = "union", leave_a_copy = "boolean"}, access = "sharing:write",
		help = "Returns {['.tag']='async_job_id', ...}; poll checkRemoveMemberJobStatus."},
	checkRemoveMemberJobStatus = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "sharing/check_remove_member_job_status", scope = "sharing.write", required = {async_job_id = "string"}, access = "sharing:write", help = job("removeFolderMember")},
	unshareFolder = {inputSchema = schema({shared_folder_id = NONEMPTY, leave_a_copy = FALSE}, {shared_folder_id = "84528192421", leave_a_copy = false}),
		route = "sharing/unshare_folder", scope = "sharing.write", required = {shared_folder_id = "string"}, access = "sharing:write",
		help = "Returns {['.tag']='complete'} or {['.tag']='async_job_id', ...}; poll checkJobStatus."},
	checkJobStatus = {inputSchema = schema({async_job_id = NONEMPTY}, {async_job_id = "job-from-start-operation"}),
		route = "sharing/check_job_status", scope = "sharing.write", required = {async_job_id = "string"}, access = "sharing:write", help = job("unshareFolder and relinquishFolderMembership")},
	mountFolder = {inputSchema = schema({shared_folder_id = NONEMPTY}, {shared_folder_id = "84528192421"}),
		route = "sharing/mount_folder", scope = "sharing.write", required = {shared_folder_id = "string"}, access = "sharing:write", help = "Returns shared folder metadata. Adds a shared folder to the account's Dropbox."},
	unmountFolder = {inputSchema = schema({shared_folder_id = NONEMPTY}, {shared_folder_id = "84528192421"}),
		route = "sharing/unmount_folder", scope = "sharing.write", required = {shared_folder_id = "string"}, access = "sharing:write", emptyResult = true, help = "Returns {success=true}. Removes it from the account's Dropbox without leaving it."},
	relinquishFolderMembership = {inputSchema = schema({shared_folder_id = NONEMPTY, leave_a_copy = FALSE}, {shared_folder_id = "84528192421", leave_a_copy = false}),
		route = "sharing/relinquish_folder_membership", scope = "sharing.write", required = {shared_folder_id = "string"}, access = "sharing:write",
		help = "Returns {['.tag']='complete'} or {['.tag']='async_job_id', ...}. Leaves a shared folder; poll checkJobStatus."},

	-- Shared files
	listReceivedFiles = {inputSchema = schema({limit = limit(300, 100), actions = FILE_ACTIONS}, {limit = 100}),
		route = "sharing/list_received_files", scope = "sharing.read", access = "sharing:read", help = "Returns {entries, cursor?}. Files others shared with the account."},
	listReceivedFilesContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "sharing/list_received_files/continue", scope = "sharing.read", required = {cursor = "string"}, access = "sharing:read", help = "Returns {entries, cursor?}. Continues listReceivedFiles while a cursor is present."},
	getSharedFileMetadata = {inputSchema = schema({file = PATH, actions = FILE_ACTIONS}, {file = "/Reports/report.pdf"}),
		route = "sharing/get_file_metadata", scope = "sharing.read", required = {file = "string"}, access = "sharing:read", help = "Returns shared file metadata. file is a path or 'id:...'."},
	listFileMembers = {inputSchema = schema({file = PATH, actions = MEMBER_ACTIONS, include_inherited = TRUE, limit = limit(300, 100)}, {file = "/Reports/report.pdf", limit = 100}),
		route = "sharing/list_file_members", scope = "sharing.read", required = {file = "string"}, access = "sharing:read", help = "Returns {users, groups, invitees, cursor?}."},
	listFileMembersContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "sharing/list_file_members/continue", scope = "sharing.read", required = {cursor = "string"}, access = "sharing:read", help = "Returns {users, groups, invitees, cursor?}. Continues listFileMembers while a cursor is present."},
	addFileMember = {inputSchema = schema({file = PATH, members = list(MEMBER), access_level = ACCESS, quiet = FALSE, custom_message = STRING, add_message_as_comment = FALSE}, {file = "/Reports/report.pdf", members = {{[".tag"] = "email", email = "ada@example.com"}}, access_level = "viewer", quiet = true}),
		route = "sharing/add_file_member", scope = "sharing.write", required = {file = "string", members = "array"}, access = "sharing:write",
		help = "Returns one result per member. Dropbox emails them unless quiet=true."},
	removeFileMember = {inputSchema = schema({file = PATH, member = MEMBER}, {file = "/Reports/report.pdf", member = {[".tag"] = "email", email = "ada@example.com"}}),
		route = "sharing/remove_file_member_2", scope = "sharing.write", required = {file = "string", member = "union"}, access = "sharing:write", help = "Returns {['.tag']='success'|'member_error', ...}."},
	unshareFile = {inputSchema = schema({file = PATH}, {file = "/Reports/report.pdf"}),
		route = "sharing/unshare_file", scope = "sharing.write", required = {file = "string"}, access = "sharing:write", emptyResult = true, help = "Returns {success=true}. Removes every member."},
	relinquishFileMembership = {inputSchema = schema({file = PATH}, {file = "/Reports/report.pdf"}),
		route = "sharing/relinquish_file_membership", scope = "sharing.write", required = {file = "string"}, access = "sharing:write", emptyResult = true, help = "Returns {success=true}. Leaves a file shared with the account."},

	-- File requests
	listFileRequests = {inputSchema = schema({limit = {type = "integer", minimum = 0, default = 1000}}, {limit = 100}),
		route = "file_requests/list_v2", scope = "file_requests.read", access = "file_requests:read", help = "Returns {file_requests, cursor, has_more}."},
	listFileRequestsContinue = {inputSchema = schema({cursor = CURSOR_SCHEMA}, {cursor = "cursor-from-previous-page"}),
		route = "file_requests/list/continue", scope = "file_requests.read", required = {cursor = "string"}, access = "file_requests:read", help = "Returns {file_requests, cursor, has_more}. Continues listFileRequests while has_more is true."},
	getFileRequest = {inputSchema = schema({id = NONEMPTY}, {id = "oaCAVmEyrqYnkZX9955Y"}),
		route = "file_requests/get", scope = "file_requests.read", required = {id = "string"}, access = "file_requests:read", help = "Returns file request."},
	createFileRequest = {inputSchema = schema({title = NONEMPTY, destination = PATH, deadline = DEADLINE, open = TRUE, description = STRING, video_project_id = STRING}, {title = "Submit reports", destination = "/Reports/Submissions", open = true}),
		route = "file_requests/create", scope = "file_requests.write", required = {title = "string", destination = "string"}, access = "file_requests:write",
		help = "Returns file request with its url. Anyone with the url can upload into destination."},
	updateFileRequest = {inputSchema = schema({id = NONEMPTY, title = NONEMPTY, destination = PATH, deadline = {oneOf = {tags({"no_update"}), variant("update", DEADLINE.properties)}}, open = {type = "boolean"}, description = STRING}, {id = "oaCAVmEyrqYnkZX9955Y", open = false}),
		route = "file_requests/update", scope = "file_requests.write", required = {id = "string"}, access = "file_requests:write", help = "Returns file request. open=false closes it; deadline={['.tag']='update'} alone clears the deadline."},
	deleteFileRequest = {inputSchema = schema({ids = list(NONEMPTY)}, {ids = {"oaCAVmEyrqYnkZX9955Y"}}),
		route = "file_requests/delete", scope = "file_requests.write", required = {ids = "array"}, access = "file_requests:write", help = "Returns {file_requests}. Only closed requests can be deleted."},
}

local help: Options = {
	text = "Dropbox API v2. Operations use Dropbox's snake_case arguments and return its JSON. Select an exact operation section for its signature, arguments, result and runnable example, or a shared topic below. Calls return completed values; do not await them. Only configured operations appear in the index.",
	functions = {},
	sections = {
		values = "Union values use a tag string for a payload-free variant, or a table such as {['.tag']='update', update='a1c10ce0dd78'}. Use json.decode('[]') for an empty list. Required top-level types are checked locally; Dropbox validates nested values and provider constraints. Extra provider options are forwarded. Routes without a result return {success=true}. Provider reference: https://www.dropbox.com/developers/documentation/http/documentation",
		paths = "Paths start with '/', are case-insensitive and use '' for the root folder (not '/'). Routes may also accept 'id:...' from metadata, 'rev:...' for a revision or 'ns:<namespace_id>/...' for accessible namespaces; support varies by route. Ordinary paths remain rooted in the member's folder. Dropbox-API-Path-Root is not set, so full team-space traversal is unsupported.",
		pagination = "Lists return one page. While has_more is true, or a sharing list returns a cursor, pass that cursor to the matching Continue operation. Keep cursors intact. There is no hidden paging. Replace example cursors with a value returned by the preceding page.",
		errors = "The connector adds no retries; Houston may retry eligible rate-limit responses. Errors report the HTTP status and Dropbox error_summary, with retryable and Retry-After when available. For example, HTTP 409 path/not_found means the path is missing or inaccessible. A failed or timed-out change may already have happened; check before repeating.",
	},
}
local exports: {[string]: any} = {help = help}
local policy: any = nil
if config.folder_policy then
	policy = require("lib/policy.luau")(config.path_access, function(path: string): Options?
		local response = await(http.request({method = "POST", url = API .. "files/get_metadata",
			headers = {["Content-Type"] = {"application/json"}}, body = json.encode({path = path, include_deleted = true})}))
		if response.statusCode < 200 or response.statusCode >= 300 then
			local ok, body = pcall(json.decode, await(response.body:readPrefix(4096)))
			if response.statusCode == 409 and ok and type(body) == "table" and type(body.error_summary) == "string"
				and string.find(body.error_summary, "path/not_found/", 1, true) == 1 then return nil end
			invalid("folderAccess", response, "Dropbox folder access could not be verified")
		end
		return decode("folderAccess", endpoints.getMetadata, response)
	end)
end

local function invoke(name: string, endpoint: Endpoint, input: any): any
	local args, context = options(endpoint, input), nil
	if policy then args, context = policy.prepare(name, args) end
	if endpoint.style == "download" then
		return download(name, endpoint, args, if policy then function(value: any): any return policy.result(name, value, context) end else nil)
	end
	local result = if endpoint.style == "upload" then upload(name, endpoint, args) else rpc(name, endpoint, args)
	return if policy then policy.result(name, result, context) else result
end

-- Exposes an operation its access rows and known OAuth scopes allow; a folder policy keeps the file
-- operations it checks, and writes only when a folder is read-write.
local function enabled(name: string, endpoint: Endpoint): boolean
	local supported = policy == nil or (policy.supports(if name == "statFile" then "getMetadata" else name)
		and (policy.writable or endpoint.access ~= "files:write")
		and (auth.scopes == nil or table.find(auth.scopes, "files.metadata.read") ~= nil))
	return supported and (endpoint.access == nil or houston.allows(endpoint.access)) and (auth.scopes == nil or table.find(auth.scopes, endpoint.scope) ~= nil)
end

for name, endpoint in endpoints do
	if enabled(name, endpoint) then
		local input = endpoint.inputSchema
		if endpoint.required then
			for field in endpoint.required do table.insert(input.required, field) end
		end
		if endpoint.style then table.insert(input.required, "session_path") end
		table.sort(input.required)
		if endpoint.void then input.additionalProperties = false end
		if policy then input = policy.schema(name, input) end
		local description = endpoint.help .. " Route: " .. endpoint.route .. "."
		if endpoint.style then description ..= " See transfers for session files and size limits." end
		if policy then description ..= " Folder access and argument restrictions apply; see folderAccess." end
		help.functions[name] = {description = description, inputSchema = input,
			args = if endpoint.void then {} else nil,
			annotations = {readOnlyHint = endpoint.access == nil or string.find(endpoint.access, ":write", 1, true) == nil}}
		exports[name] = function(args: Options?): any return invoke(name, endpoint, args) end
	end
end

-- Fixed-signature file lookup shared with other storage connectors.
if enabled("statFile", endpoints.getMetadata) then
	help.functions.statFile = {
		description = "Read normalized file metadata: {id, name, isFolder, size?}; size is absent for folders. " .. (if policy then "Takes exactly one positional ordinary absolute path inside a configured folder. IDs, revision paths and namespace aliases are not accepted; see folderAccess." else "Takes exactly one positional file path or ID; see paths."),
		args = {"id"},
		inputSchema = {type = "object", properties = {id = if policy then {type = "string", minLength = 1, pattern = "^/[^/].*", description = "Ordinary absolute path inside a configured folder; IDs, revision paths and namespace aliases are not accepted. See folderAccess."} else NONEMPTY}, required = {"id"}, additionalProperties = false,
			examples = {{id = if policy then policy.examplePath() .. "/report.pdf" else "/Reports/report.pdf"}}},
		outputSchema = object({id = NONEMPTY, name = STRING, isFolder = {type = "boolean"}, size = {type = "integer", minimum = 0, maximum = MAX_SAFE_INTEGER}}, {"id", "name", "isFolder"}),
		annotations = {readOnlyHint = true},
	}
	function exports.statFile(...: any): {id: string, name: string, isFolder: boolean, size: number?}
		assert(select("#", ...) == 1, "statFile takes exactly one file ID or path")
		local file = invoke("getMetadata", endpoints.getMetadata, {path = text((...), "file ID")})
		local isFolder = file[".tag"] == "folder"
		local size = if isFolder then nil else file.size
		if type(file.id) ~= "string" or file.id == "" or type(file.name) ~= "string"
			or (not isFolder and (type(size) ~= "number" or size < 0 or size % 1 ~= 0 or size > MAX_SAFE_INTEGER)) then
			houston.fail({operation = "statFile", layer = "upstream", retryable = false, message = "Dropbox returned invalid file metadata"})
		end
		return {id = file.id, name = file.name, isFolder = isFolder, size = size}
	end
end

if exports.listSharedLinks then
	help.sections.pagination ..= " listSharedLinks takes its cursor back in the same operation."
end
if exports.listRevisions then
	help.sections.pagination ..= " listRevisions pages with before_rev from the last entry while has_more is true."
end
if exports.search then
	help.sections.pagination ..= " Search returns at most 10,000 matches across pages; indexing can lag, and results may repeat or be omitted."
end
if exports.download or exports.downloadZip or exports.export or exports.getPreview or exports.getThumbnail or exports.getSharedLinkFile or exports.upload then
	help.sections.transfers = "Content operations transfer session files; never inline file bytes. A transfer must finish within the call's time limit and stops at Houston's 256 MiB file limit."
	if exports.download or exports.downloadZip or exports.export or exports.getPreview or exports.getThumbnail or exports.getSharedLinkFile then
		help.sections.transfers ..= " Downloads save to session_path and return {session_path, url, size, result}; url is a signed Houston link, size counts bytes, and result is Dropbox metadata. A failed download leaves the existing session file unchanged."
	end
	if exports.upload then
		help.sections.transfers ..= " upload reads an existing session_path and stops at Dropbox's 150 MiB single-request limit. Create the session file before running its example. mode defaults to add; overwrite replaces the existing file and update checks its revision."
	end
end
if exports.saveUrlCheckJobStatus or exports.moveBatchCheck or exports.copyBatchCheck or exports.deleteBatchCheck or exports.checkJobStatus or exports.checkShareJobStatus or exports.checkRemoveMemberJobStatus then
	help.sections.jobs = "Some mutations return {['.tag']='async_job_id', async_job_id=...}; call the status operation named in that function's section. Replace example job IDs with the returned ID. There is no hidden polling. Inspect the final tag and every batch entry: HTTP success does not guarantee all entries succeeded, and a failed job may have partially changed data. Check state before retrying."
end
if policy then
	help.sections.folderAccess = policy.help()
	help.sections.paths = "Folder limits require ordinary absolute paths in the member's folder, not IDs, namespace aliases or revision paths. Begin at an explicitly granted folder; path='' requires a '/' rule. Parent folders must exist before creating a child. Full team-space traversal is unsupported. See folderAccess for the configured grants."
	help.sections.values = "Union values use tag strings or {['.tag']=...} tables. Use json.decode('[]') for an empty list. Only the options in each operation's schema are available with folder limits. Dropbox validates nested values and provider constraints."
	help.sections.pagination ..= " Folder pagination cursors are Houston tokens tied to this connection and its settings."
end
return exports
