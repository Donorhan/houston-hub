-- Gmail API v1 for the connected mailbox. Arguments and results keep Google's native
-- field names; reads add decoded bodies and writes build MIME so callers never handle base64.
local API = "https://gmail.googleapis.com/gmail/v1/users/me"
local UPLOAD = "https://gmail.googleapis.com/upload/gmail/v1/users/me"

-- Request layer shared verbatim by the Google connectors (tools/validate checks they match).
type Options = {[string]: any}
type Endpoint = {method: string, path: string, access: string?, query: {string}?, body: boolean?, defaults: Options?, list: string?, required: {[string]: string}?, help: string}

local function text(value: any, field: string): string
	assert(type(value) == "string" and value ~= "", field .. " must be a nonempty string")
	return value
end

local function options(value: any): Options
	if value == nil then return {} end
	assert(type(value) == "table", "opts must be an object")
	for key in value do assert(type(key) == "string", "opts must have named fields") end
	return table.clone(value)
end

-- Moves the named fields from args into a query string; arrays repeat the key.
local function query(args: Options, names: {string}): string
	local parts: {string} = {}
	for _, name in names do
		local value = args[name]
		args[name] = nil
		for key, item in (if type(value) == "table" then value else {value}) do
			assert(type(key) == "number" and (type(item) == "string" or type(item) == "number" or type(item) == "boolean"), name .. " must be a string, number, boolean or an array of them")
			table.insert(parts, url.encode(name) .. "=" .. url.encode(item))
		end
	end
	return if #parts > 0 then "?" .. table.concat(parts, "&") else ""
end

-- Older APIs name the reason in errors[], newer ones in an ErrorInfo detail.
local function reasonOf(problem: any): string?
	for _, list in {problem.errors, problem.details} :: {any} do
		if type(list) == "table" then
			for _, item in list do
				if type(item) == "table" and type(item.reason) == "string" then return item.reason end
			end
		end
	end
	return nil
end

local function fail(operation: string, response: HttpResponse): never
	local ok, decoded = pcall(json.decode, await(response.body:readPrefix(4096)))
	local problem = if ok and type(decoded) == "table" and type(decoded.error) == "table" then decoded.error else {}
	local reason = reasonOf(problem)
	local message = "Google HTTP " .. tostring(response.statusCode)
	if type(problem.status) == "string" then message ..= " (" .. problem.status .. ")" end
	if type(problem.message) == "string" then message ..= ": " .. string.sub(problem.message, 1, 600) end
	if reason then message ..= " [" .. reason .. "]" end
	local retry = response.headers["retry-after"]
	if retry and retry[1] then message ..= "; Retry-After: " .. retry[1] end
	local limited = reason ~= nil and string.find(string.lower(reason), "ratelimitexceeded", 1, true) ~= nil
	return houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode,
		retryable = response.statusCode == 429 or response.statusCode >= 500 or limited, message = message})
end

local function decode(operation: string, response: HttpResponse): any
	if response.statusCode < 200 or response.statusCode >= 300 then fail(operation, response) end
	local raw = await(response.body:readAll())
	if raw == "" then return {success = true} end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" or not string.match(raw, "^%s*{") then
		houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode,
			retryable = false, message = "Google returned an invalid JSON object"})
	end
	return value
end

local function call(operation: string, method: string, href: string, body: any?): any
	return decode(operation, await(http.request({method = method, url = href,
		headers = if body ~= nil then {["Content-Type"] = {"application/json"}} else nil,
		body = if body ~= nil then json.encode(body) else nil})))
end

-- Accepts a docs.google.com editor URL in place of its file ID; published and responder links (/d/e/...) carry no ID.
local function docsId(value: any, product: string, field: string): any
	if type(value) ~= "string" then return value end
	local rest = string.match(value, "^https://docs%.google%.com/" .. product .. "/d/(.*)$")
		or string.match(value, "^https://docs%.google%.com/" .. product .. "/u/%d+/d/(.*)$")
		or string.match(value, "^https://docs%.google%.com/a/[^/]+/" .. product .. "/d/(.*)$")
	local id: string = if rest then string.match(rest, "^[^/?#]*") or "" else value
	assert(string.match(id, "^[%w_%-]+$") and id ~= "e", field .. " must be an ID or its https://docs.google.com/" .. product .. "/d/<id> URL")
	return id
end

-- Moves {placeholders} and declared query fields from args into the URL; remaining fields form the JSON body.
local function target(name: string, endpoint: Endpoint, args: Options): string
	local defaults: Options = endpoint.defaults or {}
	for key, value in defaults do
		if args[key] == nil then args[key] = value end
	end
	local required: {[string]: string} = endpoint.required or {}
	for field, kind in required do
		local value = args[field]
		assert(if kind == "array" then type(value) == "table" and value[1] ~= nil elseif kind == "string" then type(value) == "string" and value ~= "" elseif kind == "object" then type(value) == "table" and next(value) ~= nil and value[1] == nil else false,
			name .. " requires " .. field .. " as a nonempty " .. kind)
	end
	local path = string.gsub(endpoint.path, "{(%w+)}", function(field: string)
		local value = url.segment(text(args[field], field), field)
		args[field] = nil
		return value
	end)
	path ..= query(args, endpoint.query or {})
	if not endpoint.body then assert(next(args) == nil, name .. " received an unknown option") end
	return API .. path
end

local function invoke(name: string, endpoint: Endpoint, input: any): any
	local args = options(input)
	local result = call(name, endpoint.method, target(name, endpoint, args), if endpoint.body then args else nil)
	if endpoint.list and result[endpoint.list] == nil then result[endpoint.list] = json.decode("[]") end
	return result
end

local exports: {[string]: any} = {}
local help: {[string]: string} = {}

-- Exposes an operation when the connection allows the access it needs, if any.
local function export(name: string, access: string?, fn: (any) -> any, doc: string)
	if access == nil or houston.allows(access) then
		exports[name], help[name] = fn, doc
	end
end

local function exportEndpoints(endpoints: {[string]: Endpoint})
	for name, endpoint in endpoints do
		export(name, endpoint.access, function(args: Options?): any return invoke(name, endpoint, args) end, endpoint.help)
	end
end

-- help() introduces the API, then documents exactly the configured operations.
local function helpWith(overview: {string}): () -> string
	return function(): string
		local names: {string} = {}
		for name in help do table.insert(names, name) end
		table.sort(names)
		local lines = table.clone(overview)
		for _, name in names do table.insert(lines, help[name]) end
		return table.concat(lines, "\n")
	end
end
-- End of the shared request layer.

-- Keep Gmail documentation outside the shared Google transport contract.
local reference = {
	text = "Gmail API v1 for the connected mailbox. Call operations directly, without await, using Google's camelCase options. Access: messages " .. access.messages .. ", drafts " .. access.drafts .. ", sending " .. access.sending .. ". Only configured operations appear below. Nothing deletes or trashes mail. Use help({section='operationName'}) for a complete signature and example.",
	functions = {} :: {[string]: any},
	sections = {errors = "Errors report Google's HTTP status, message and reason. The connector does not retry or page automatically; Houston may retry short HTTP 429 responses."} :: {[string]: string},
}
if houston.allows("messages:read") or houston.allows("drafts:manage") then
	reference.sections.pagination = "Lists return one page. Pass nextPageToken as pageToken until it is absent; resultSizeEstimate is approximate. Use small pages."
		.. (if houston.allows("messages:read") then " Message lists carry IDs only: fetch details with getMessages or getThread; use metadata reads when scanning mail." else " Draft lists carry IDs only: fetch content with getDraft.")
end
if houston.allows("messages:organize") or houston.allows("drafts:create") or houston.allows("sending:send") then
	reference.sections.errors ..= " A failed or timed-out write may already have succeeded. Inspect the outcome before repeating."
end
local STRING = {type = "string"}
local ID = {type = "string", minLength = 1}
local STRINGS = {type = "array", items = ID}
local HISTORY_TYPE: Options = {type = "string", enum = {"messageAdded", "messageDeleted", "labelAdded", "labelRemoved"}}
local INTEGER = {type = "integer"}
local function object(properties: Options, required: {string}?, extra: boolean?): Options
	return {type = "object", properties = properties, required = if required and #required > 0 then required else json.decode("[]"), additionalProperties = extra == true}
end
local function input(properties: Options, required: {string}, example: Options): Options
	local schema = object(properties, required)
	schema.examples = {example}
	return schema
end
local messageRef = object({id = ID, threadId = ID, labelIds = STRINGS}, {"id"}, true)
local label = object({id = ID, name = STRING, type = STRING, labelListVisibility = STRING, messageListVisibility = STRING,
	messagesTotal = INTEGER, messagesUnread = INTEGER, threadsTotal = INTEGER, threadsUnread = INTEGER,
	color = object({textColor = STRING, backgroundColor = STRING}, nil, true)}, {"id"}, true)
local draftRef = object({id = ID, message = messageRef}, {"id"}, true)
local SUCCESS = object({success = {const = true}}, {"success"})
local PAGE = {type = "integer", minimum = 1, maximum = 500, default = 100}
local searchProperties = {q = {type = "string", description = "Gmail search syntax, e.g. from:ana@example.com has:attachment."},
	labelIds = {oneOf = {STRING, STRINGS}}, maxResults = PAGE, pageToken = STRING, includeSpamTrash = {type = "boolean", default = false}}
local function pageSchema(key: string, item: Options): Options
	return object({[key] = {type = "array", items = item}, nextPageToken = STRING, resultSizeEstimate = INTEGER}, {key}, true)
end
local labelChanges = {id = ID, addLabelIds = {type = "array", items = {type = "string", minLength = 1, ["not"] = {enum = {"TRASH", "SPAM"}}}}, removeLabelIds = STRINGS}
local labelFields = {name = ID, labelListVisibility = {type = "string", enum = {"labelShow", "labelShowIfUnread", "labelHide"}},
	messageListVisibility = {type = "string", enum = {"show", "hide"}}, color = object({textColor = STRING, backgroundColor = STRING}, nil, true)}

type DocumentedEndpoint = Endpoint & {inputSchema: Options, outputSchema: Options}
local SEARCH = {"q", "labelIds", "maxResults", "pageToken", "includeSpamTrash"}
local endpoints: {[string]: DocumentedEndpoint} = {
	listLabels = {method = "GET", path = "/labels", access = "messages:read", list = "labels",
		help = "Lists all mailbox labels. System labels include INBOX, SENT, DRAFT, SPAM, TRASH, UNREAD, STARRED and IMPORTANT.",
		inputSchema = input({}, {}, {}), outputSchema = object({labels = {type = "array", items = label}}, {"labels"})},
	getLabel = {method = "GET", path = "/labels/{id}", access = "messages:read",
		help = "Reads one label, including message and thread counts.",
		inputSchema = input({id = ID}, {"id"}, {id = "INBOX"}), outputSchema = label},
	listMessages = {method = "GET", path = "/messages", access = "messages:read", list = "messages", query = SEARCH,
		help = "Searches one page of message IDs and thread IDs. Fetch bodies with getMessages. Pass nextPageToken back as pageToken; resultSizeEstimate is approximate.",
		inputSchema = input(searchProperties, {}, {q = "is:unread in:inbox", maxResults = 20}), outputSchema = pageSchema("messages", messageRef)},
	listThreads = {method = "GET", path = "/threads", access = "messages:read", list = "threads", query = SEARCH,
		help = "Searches one page of conversations, returning id, snippet and historyId, without messages. Read a conversation with getThread. Pass nextPageToken as pageToken.",
		inputSchema = input(searchProperties, {}, {q = "from:ana@example.com", maxResults = 20}), outputSchema = pageSchema("threads", object({id = ID, snippet = STRING, historyId = STRING}, {"id"}, true))},
	listDrafts = {method = "GET", path = "/drafts", access = "drafts:manage", list = "drafts", query = {"q", "maxResults", "pageToken", "includeSpamTrash"},
		help = "Lists one page of draft IDs and message IDs, without content. Read content with getDraft; pass nextPageToken as pageToken.",
		inputSchema = input({q = STRING, maxResults = PAGE, pageToken = STRING, includeSpamTrash = {type = "boolean", default = false}}, {}, {maxResults = 20}), outputSchema = pageSchema("drafts", draftRef)},
	listHistory = {method = "GET", path = "/history", access = "messages:read", list = "history", query = {"startHistoryId", "labelId", "historyTypes", "maxResults", "pageToken"},
		help = "Lists changes after startHistoryId, in chronological order. Pass nextPageToken as pageToken. An expired history ID returns HTTP 404: resync with listMessages. Keep historyId as a string.",
		inputSchema = input({startHistoryId = ID, labelId = ID, historyTypes = {oneOf = {HISTORY_TYPE, {type = "array", items = HISTORY_TYPE}}}, maxResults = PAGE, pageToken = STRING}, {"startHistoryId"}, {startHistoryId = "12345", maxResults = 20}),
		outputSchema = object({history = {type = "array", items = object({id = STRING, messages = {type = "array", items = messageRef}, messagesAdded = {type = "array", items = object({message = messageRef})}, messagesDeleted = {type = "array", items = object({message = messageRef})}, labelsAdded = {type = "array", items = object({message = messageRef, labelIds = STRINGS})}, labelsRemoved = {type = "array", items = object({message = messageRef, labelIds = STRINGS})}}, nil, true)}, historyId = STRING, nextPageToken = STRING}, {"history"}, true)},
	modifyMessage = {method = "POST", path = "/messages/{id}/modify", access = "messages:organize", body = true,
		help = "Changes labels on one message, preserving other labels. Remove UNREAD to mark read, add UNREAD to mark unread, or remove INBOX to archive. Adding TRASH or SPAM is refused. At most 100 labels per add/remove list.",
		inputSchema = input(labelChanges, {"id"}, {id = "m1", removeLabelIds = {"UNREAD"}}), outputSchema = messageRef},
	batchModifyMessages = {method = "POST", path = "/messages/batchModify", access = "messages:organize", body = true,
		help = "Changes labels on up to 1000 message IDs. Remove UNREAD to mark read or INBOX to archive. Adding TRASH or SPAM is refused. An interrupted batch may already have changed mail; inspect before replaying.",
		inputSchema = input({ids = {type = "array", items = ID, minItems = 1, maxItems = 1000}, addLabelIds = labelChanges.addLabelIds, removeLabelIds = STRINGS}, {"ids"}, {ids = {"m1", "m2"}, removeLabelIds = {"UNREAD"}}), outputSchema = SUCCESS},
	modifyThread = {method = "POST", path = "/threads/{id}/modify", access = "messages:organize", body = true,
		help = "Changes labels on every message in a conversation. Remove INBOX to archive or UNREAD to mark read. Adding TRASH or SPAM is refused. At most 100 labels per add/remove list. Returns Gmail's raw thread with raw messages, not decoded bodies.",
		inputSchema = input(labelChanges, {"id"}, {id = "t1", removeLabelIds = {"INBOX"}}), outputSchema = object({id = ID, historyId = STRING, messages = {type = "array", items = messageRef}}, {"id"}, true)},
	createLabel = {method = "POST", path = "/labels", access = "messages:organize", body = true,
		help = "Creates a mailbox label. Use Parent/Child names to nest labels. Colors must be from Gmail's supported palette.",
		inputSchema = input(labelFields, {"name"}, {name = "Projects/Launch"}), outputSchema = label},
	updateLabel = {method = "PATCH", path = "/labels/{id}", access = "messages:organize", body = true,
		help = "Updates specified label properties, preserving the others. Colors must be from Gmail's supported palette.",
		inputSchema = input({id = ID, name = ID, labelListVisibility = labelFields.labelListVisibility, messageListVisibility = labelFields.messageListVisibility, color = labelFields.color}, {"id"}, {id = "Label_1", name = "Projects/Launch"}), outputSchema = label},
	deleteLabel = {method = "DELETE", path = "/labels/{id}", access = "messages:organize",
		help = "Deletes a user label and removes it from messages. The messages remain.",
		inputSchema = input({id = ID}, {"id"}, {id = "Label_1"}), outputSchema = SUCCESS},
	deleteDraft = {method = "DELETE", path = "/drafts/{id}", access = "drafts:manage",
		help = "Permanently deletes a draft without sending it.",
		inputSchema = input({id = ID}, {"id"}, {id = "d1"}), outputSchema = SUCCESS},
}

local function header(headers: any, name: string): string?
	for _, item in headers or {} do
		if type(item) == "table" and type(item.name) == "string" and string.lower(item.name) == name then return item.value end
	end
	return nil
end

-- Gmail returns body bytes in their original charset; non-UTF-8 text is read as Latin-1.
local function bodyText(data: string): string
	local value = base64.decode(data)
	if utf8.len(value) == nil then
		value = string.gsub(value, "[\128-\255]", function(c: string) return utf8.char(string.byte(c)) end)
	end
	return value
end

local function limitBody(value: string, limit: number): (string, boolean)
	if limit == 0 or #value <= limit then return value, false end
	value = string.sub(value, 1, limit)
	while utf8.len(value) == nil do value = string.sub(value, 1, -2) end
	return value, true
end

local function collect(part: any, found: Options)
	if type(part.parts) == "table" then
		for _, child in part.parts do collect(child, found) end
		return
	end
	local body = part.body or {}
	local disposition = string.lower(header(part.headers, "content-disposition") or "")
	local attached = string.sub(disposition, 1, 10) == "attachment"
	local filename = if type(part.filename) == "string" and part.filename ~= "" then part.filename else nil
	if not filename and not attached and (part.mimeType == "text/plain" or part.mimeType == "text/html") then
		found[part.mimeType] = found[part.mimeType] or {}
		table.insert(found[part.mimeType], body)
	elseif type(body.attachmentId) == "string" then
		local contentId = header(part.headers, "content-id")
		table.insert(found.attachments, {id = body.attachmentId, filename = filename, mimeType = part.mimeType, size = body.size,
			inline = not attached and (contentId ~= nil or string.sub(disposition, 1, 6) == "inline"),
			contentId = if contentId then string.match(contentId, "^%s*<?(.-)>?%s*$") else nil})
	end
end

-- Match Unicode White_Space, as the native IMAP reader does; preserve the original text.
local function hasContent(value: string): boolean
	for _, point in utf8.codes(value) do
		if not ((point >= 9 and point <= 13) or point == 32 or point == 0x85 or point == 0xA0 or point == 0x1680
			or (point >= 0x2000 and point <= 0x200A) or point == 0x2028 or point == 0x2029 or point == 0x202F or point == 0x205F or point == 0x3000) then
			return true
		end
	end
	return false
end

-- Replaces Gmail's MIME payload with envelope fields, one decoded body and attachment metadata.
local function message(raw: Options, limit: number, bodyFormat: string): Options
	local payload = raw.payload or {}
	local headers = payload.headers or json.decode("[]")
	local found: Options = {attachments = json.decode("[]")}
	collect(payload, found)
	local body, unread = "", false
	local mimeTypes: {string} = if bodyFormat == "auto" then {"text/plain", "text/html"} else {if bodyFormat == "text" then "text/plain" else "text/html"}
	for _, mimeType in mimeTypes do
		local parts: {Options} = found[mimeType] or {}
		for _, part in parts do
			local data = part.data
			if (data == nil or data == "") and type(part.attachmentId) == "string" then
				if houston.allows("messages:read") then
					data = call("getMessage", "GET", API .. "/messages/" .. url.segment(raw.id, "id") .. "/attachments/" .. url.segment(part.attachmentId, "attachmentId")).data
				else
					unread = true
				end
			end
			if type(data) == "string" then body = bodyText(data) end
			if bodyFormat ~= "auto" or hasContent(body) then break end
		end
		if bodyFormat ~= "auto" or hasContent(body) then break end
		body = ""
	end
	if bodyFormat == "auto" and body == "" then body = raw.snippet or "" end
	local truncated: boolean
	body, truncated = limitBody(body, limit)
	truncated = truncated or unread
	return {
		id = raw.id, threadId = raw.threadId, labelIds = raw.labelIds or json.decode("[]"), snippet = raw.snippet,
		historyId = raw.historyId, internalDate = raw.internalDate, sizeEstimate = raw.sizeEstimate,
		from = header(headers, "from"), to = header(headers, "to"), cc = header(headers, "cc"), bcc = header(headers, "bcc"),
		replyTo = header(headers, "reply-to"), subject = header(headers, "subject"), date = header(headers, "date"),
		messageId = header(headers, "message-id"), body = body, bodyTruncated = truncated, attachments = found.attachments, headers = headers,
	}
end

-- Moves the read options from args into a query string; returns it with the body byte limit.
local function readQuery(args: Options): (string, number, string)
	local limit = args.maxBodyBytes or 65536
	assert(type(limit) == "number" and limit >= 0 and limit % 1 == 0, "maxBodyBytes must be a nonnegative integer")
	local format = args.format or "full"
	assert(format == "full" or format == "metadata" or format == "minimal", "format must be full, metadata or minimal")
	local bodyFormat = if args.bodyFormat == nil then "auto" else args.bodyFormat
	assert(bodyFormat == "auto" or bodyFormat == "text" or bodyFormat == "html", "bodyFormat must be auto, text or html")
	args.maxBodyBytes, args.format, args.bodyFormat = nil, format, nil
	return query(args, {"format", "metadataHeaders"}), limit, bodyFormat
end

local function read(name: string, collection: string, input: any): (any, number, string)
	local args = options(input)
	local id = text(args.id, "id")
	args.id = nil
	local suffix, limit, bodyFormat = readQuery(args)
	assert(next(args) == nil, name .. " received an unknown option")
	return call(name, "GET", API .. "/" .. collection .. "/" .. url.segment(id, "id") .. suffix), limit, bodyFormat
end

local function getMessages(input: any): {Options}
	local args = options(input)
	local ids = args.ids
	assert(type(ids) == "table" and #ids >= 1 and #ids <= 100, "ids must be an array of 1 to 100 message IDs")
	local segments: {string} = {}
	for i = 1, #ids do
		local field = "ids[" .. tostring(i) .. "]"
		segments[i] = url.segment(text(ids[i], field), field)
	end
	args.ids = nil
	local suffix, limit, bodyFormat = readQuery(args)
	assert(next(args) == nil, "getMessages received an unknown option")
	local out: {Options} = json.decode("[]")
	-- Bounded concurrency stays within Gmail's per-user rate limits.
	for first = 1, #ids, 10 do
		local pending = {}
		for i = first, math.min(first + 9, #ids) do
			table.insert(pending, http.request({method = "GET", url = API .. "/messages/" .. segments[i] .. suffix}))
		end
		local responses = awaitAll(pending)
		for i = 1, responses.n do table.insert(out, message(decode("getMessages", responses[i]), limit, bodyFormat)) end
	end
	return out
end

-- Gmail returns {"size": n, "data": "<base64url>"}; decode the data string as it streams so
-- large attachments never sit in memory.
local function getAttachment(input: any): Options
	local args = options(input)
	local messageId, attachmentId, path = text(args.messageId, "messageId"), text(args.attachmentId, "attachmentId"), text(args.path, "path")
	args.messageId, args.attachmentId, args.path = nil, nil, nil
	assert(next(args) == nil, "getAttachment received an unknown option")
	local response = await(http.request({method = "GET", url = API .. "/messages/" .. url.segment(messageId, "messageId") .. "/attachments/" .. url.segment(attachmentId, "attachmentId")}))
	if response.statusCode < 200 or response.statusCode >= 300 then fail("getAttachment", response) end
	local output = fs.open(path, "w")
	local pending, started, finished = "", false, false
	while not finished do
		local chunk = await(response.body:read(1048576))
		if chunk.done then break end
		pending ..= chunk.data
		if not started then
			local _, last = string.find(pending, '"data"%s*:%s*"')
			if last then started, pending = true, string.sub(pending, last + 1) end
		end
		if started then
			local close = string.find(pending, '"', 1, true)
			finished = close ~= nil
			local usable = if close then close - 1 else #pending - #pending % 4
			await(output:write(base64.decode(string.sub(pending, 1, usable))))
			pending = string.sub(pending, usable + 1)
		end
	end
	response.body:close()
	if not finished then
		output:cancel()
		pcall(function() await(output:close()) end)
		houston.fail({operation = "getAttachment", layer = "upstream", upstream_status = response.statusCode, retryable = false, message = "Google returned no attachment data"})
	end
	await(output:close())
	return {path = path, url = await(fs.signedGetUrl(path)), size = await(fs.stat(path)).size}
end

local EMAIL = "[%w%.%_%%%+%-]+@[%w%.%-]+"

local function line(name: string, value: string?): string
	if value == nil then return "" end
	assert(not string.find(value, "[\r\n]"), name .. " must not contain line breaks")
	return name .. ": " .. value .. "\r\n"
end

local function addresses(value: any, field: string): string?
	if value == nil then return nil end
	local list = if type(value) == "string" then {value} else value
	assert(type(list) == "table" and #list > 0, field .. " must be an address or an array of addresses")
	for _, item in list do assert(type(item) == "string" and item ~= "", field .. " must contain address strings") end
	return table.concat(list, ", ")
end

-- Appends one base64-encoded MIME part.
local function part(out: {string}, contentType: string, data: string, disposition: string?)
	table.insert(out, line("Content-Type", contentType) .. line("Content-Disposition", disposition) .. "Content-Transfer-Encoding: base64\r\n\r\n")
	table.insert(out, base64.encode(data, {wrap = true}))
end

-- Returns the opening, separating and closing lines of a multipart body.
-- Base64 parts never contain "=_", so these fixed boundaries cannot collide with content.
local function multipart(subtype: string): (string, string, string)
	local boundary = "=_houston_" .. subtype
	return "Content-Type: multipart/" .. subtype .. "; boundary=\"" .. boundary .. "\"\r\n\r\n--" .. boundary .. "\r\n",
		"\r\n--" .. boundary .. "\r\n", "\r\n--" .. boundary .. "--\r\n"
end

local function attachment(out: {string}, item: any)
	local spec = if type(item) == "string" then {path = item} else item
	assert(type(spec) == "table", "attachments must be paths or {path, filename?, mimeType?}")
	local path = text(spec.path, "attachment path")
	local filename = text(spec.filename or string.match(path, "[^/]+$"), "attachment filename")
	local file = fs.open(path, "r")
	local data = await(file:readAll())
	await(file:close())
	local name = if string.match(filename, "^[%w%.%-_ ()]+$") then "filename=\"" .. filename .. "\"" else "filename*=UTF-8''" .. url.encode(filename)
	part(out, text(spec.mimeType or "application/octet-stream", "attachment mimeType"), data, "attachment; " .. name)
end

-- The mailbox's own address, which a reply to all leaves out. Google sign-in grants only narrow
-- Gmail scopes, none of which reads the profile, so it asks the userinfo endpoint instead.
local function ownAddress(name: string): string
	if auth.method == "oauth" then return call(name, "GET", "https://www.googleapis.com/oauth2/v2/userinfo").email or "" end
	return call(name, "GET", API .. "/profile").emailAddress or ""
end

-- Builds the MIME message as pieces and returns them with the thread to post into. inReplyTo
-- threads a reply to that message: recipients, subject and references default from the original.
-- Otherwise, replacing a draft keeps its thread, threading headers and, if omitted, subject:
-- Gmail moves a draft out of its conversation when an update leaves them out.
local function compose(name: string, args: Options, replacing: string?): ({string}, string?)
	local known = {}
	for _, field in {"to", "cc", "bcc", "replyTo", "from", "subject", "text", "html", "attachments", "inReplyTo", "replyAll"} do known[field] = true end
	for key in args do assert(known[key], name .. " received an unknown option " .. key) end
	local to, cc, subject, threadId, references, inReplyTo = addresses(args.to, "to"), addresses(args.cc, "cc"), args.subject, nil, nil, nil
	if args.inReplyTo ~= nil then
		assert(houston.allows("messages:read"), name .. " with inReplyTo needs Messages access set to Read, to read the message it answers")
		local metadata = {format = "metadata", metadataHeaders = {"From", "Reply-To", "To", "Cc", "Subject", "Message-ID", "References"}}
		local original = call(name, "GET", API .. "/messages/" .. url.segment(text(args.inReplyTo, "inReplyTo"), "inReplyTo") .. query(metadata, {"format", "metadataHeaders"}))
		local headers = original.payload and original.payload.headers
		threadId, inReplyTo = original.threadId, header(headers, "message-id")
		references = if inReplyTo then table.concat({header(headers, "references") or "", inReplyTo}, " ") else nil
		to = to or header(headers, "reply-to") or header(headers, "from")
		if subject == nil then
			local previous = header(headers, "subject") or ""
			subject = if string.match(string.lower(previous), "^re:") then previous else "Re: " .. previous
		end
		if args.replyAll == true and cc == nil then
			local seen = {[string.lower(ownAddress(name))] = true}
			for email in string.gmatch(string.lower(to or ""), EMAIL) do seen[email] = true end
			local copied: {string} = {}
			for email in string.gmatch(string.lower((header(headers, "to") or "") .. "," .. (header(headers, "cc") or "")), EMAIL) do
				if not seen[email] then seen[email], copied[#copied + 1] = true, email end
			end
			cc = if #copied > 0 then table.concat(copied, ", ") else nil
		end
	elseif replacing then
		local current = call(name, "GET", API .. "/drafts/" .. replacing .. "?format=metadata").message or {}
		local headers = current.payload and current.payload.headers
		threadId, inReplyTo, references = current.threadId, header(headers, "in-reply-to"), header(headers, "references")
		subject = if subject == nil then header(headers, "subject") else subject
	end
	assert(to, name .. " requires to (or inReplyTo)")
	assert(args.text ~= nil or args.html ~= nil, name .. " requires text or html")
	local attachments = if args.attachments == nil then {} else args.attachments
	assert(type(attachments) == "table", "attachments must be an array")
	if subject ~= nil and string.find(subject, "[\128-\255]") then subject = "=?UTF-8?B?" .. base64.encode(subject) .. "?=" end
	local out = {line("From", args.from) .. line("To", to) .. line("Cc", cc) .. line("Bcc", addresses(args.bcc, "bcc"))
		.. line("Reply-To", addresses(args.replyTo, "replyTo")) .. line("Subject", subject) .. line("In-Reply-To", inReplyTo)
		.. line("References", references) .. "MIME-Version: 1.0\r\n"}
	local open, between, close = multipart("mixed")
	if #attachments > 0 then table.insert(out, open) end
	if args.text ~= nil and args.html ~= nil then
		local first, second, last = multipart("alternative")
		table.insert(out, first)
		part(out, "text/plain; charset=UTF-8", text(args.text, "text"))
		table.insert(out, second)
		part(out, "text/html; charset=UTF-8", text(args.html, "html"))
		table.insert(out, last)
	elseif args.html ~= nil then
		part(out, "text/html; charset=UTF-8", text(args.html, "html"))
	else
		part(out, "text/plain; charset=UTF-8", text(args.text, "text"))
	end
	if #attachments > 0 then
		for _, item in attachments do
			table.insert(out, between)
			attachment(out, item)
		end
		table.insert(out, close)
	end
	return out, threadId
end

-- Uploads the message as message/rfc822 beside Gmail's JSON metadata, so attachments are
-- base64-encoded only once. Drafts nest the thread under message.
local function submit(name: string, method: string, path: string, args: Options, draft: boolean, replacing: string?): any
	local mime, threadId = compose(name, args, replacing)
	local metadata = if draft then {message = {threadId = threadId}} else {threadId = threadId}
	local body = {"--=_houston_upload\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" .. json.encode(metadata)
		.. "\r\n--=_houston_upload\r\nContent-Type: message/rfc822\r\n\r\n"}
	table.move(mime, 1, #mime, 2, body)
	table.insert(body, "\r\n--=_houston_upload--\r\n")
	return decode(name, await(http.request({method = method, url = UPLOAD .. path .. "?uploadType=multipart",
		headers = {["Content-Type"] = {"multipart/related; boundary=\"=_houston_upload\""}}, body = table.concat(body)})))
end

for name, endpoint in endpoints do
	if endpoint.access == nil or houston.allows(endpoint.access) then
		-- Body fields pass through to Gmail; query-only endpoints reject unknown options.
		endpoint.inputSchema.additionalProperties = endpoint.body == true
		reference.functions[name] = {description = endpoint.help, inputSchema = endpoint.inputSchema,
			outputSchema = endpoint.outputSchema, annotations = {readOnlyHint = endpoint.method == "GET", openWorldHint = true}}
		exports[name] = function(args: Options?): any return invoke(name, endpoint, args) end
	end
end

-- Gmail moves a message that gains one of these labels to Trash or Spam, where it is deleted
-- after 30 days. The proxy cannot read request bodies, so the modify operations refuse them here.
for _, name in {"modifyMessage", "batchModifyMessages", "modifyThread"} do
	local modify = exports[name]
	if modify then
		exports[name] = function(input: any): any
			local added: {any} = if type(input) == "table" and type(input.addLabelIds) == "table" then input.addLabelIds else {}
			for _, label in added do
				assert(string.upper(tostring(label)) ~= "TRASH" and string.upper(tostring(label)) ~= "SPAM", name .. " cannot add " .. tostring(label) .. ": nothing moves mail to Trash or Spam")
			end
			return modify(input)
		end
	end
end

local READ_OPTIONS = "bodyFormat auto (default) chooses the first nonblank decoded plain text, HTML, then snippet; text or html selects only that format, preserving whitespace and returning an empty string if missing. format full (default) decodes the body, metadata returns headers, minimal returns identifiers/labels. metadataHeaders limits metadata headers. maxBodyBytes caps each selected body (default 65536, 0 for no cap), preserving UTF-8 and setting bodyTruncated. A body cap does not bound the whole result; use small batches."
local readProperties = {id = ID, format = {type = "string", enum = {"full", "metadata", "minimal"}, default = "full"},
	metadataHeaders = {oneOf = {STRING, STRINGS}}, maxBodyBytes = {type = "integer", minimum = 0, default = 65536},
	bodyFormat = {type = "string", enum = {"auto", "text", "html"}, default = "auto"}}
local messageSchema = object({id = ID, threadId = ID, labelIds = STRINGS, snippet = STRING, historyId = STRING,
	internalDate = {type = "string", description = "Epoch milliseconds, preserved as Google's string."}, sizeEstimate = INTEGER,
	from = STRING, to = STRING, cc = STRING, bcc = STRING, replyTo = STRING, subject = STRING, date = STRING, messageId = STRING,
	body = STRING, bodyTruncated = {type = "boolean"},
	attachments = {type = "array", items = object({id = ID, filename = STRING, mimeType = STRING, size = INTEGER, inline = {type = "boolean"}, contentId = STRING}, {"id", "inline"})},
	headers = {oneOf = {{type = "array", items = object({name = STRING, value = STRING}, {"name", "value"})}, {type = "object", maxProperties = 0}} :: {Options}}}, {"labelIds", "body", "bodyTruncated", "attachments", "headers"})
if houston.allows("messages:read") or houston.allows("drafts:manage") then reference.sections.reading = READ_OPTIONS end

if houston.allows("messages:read") then
	reference.functions.getMessage = {
		description = "Reads one message with decoded body, envelope headers and attachment metadata; it does not return Gmail's MIME payload. " .. READ_OPTIONS,
		inputSchema = input(readProperties, {"id"}, {id = "m1", maxBodyBytes = 4096}), outputSchema = messageSchema,
		annotations = {readOnlyHint = true, openWorldHint = true},
	}
	function exports.getMessage(input: any): Options
		local raw, limit, bodyFormat = read("getMessage", "messages", input)
		return message(raw, limit, bodyFormat)
	end

	local batchReadProperties: Options = table.clone(readProperties)
	batchReadProperties.id = nil
	batchReadProperties.ids = {type = "array", items = ID, minItems = 1, maxItems = 100}
	reference.functions.getMessages = {
		description = "Reads 1 to 100 messages in input ID order. Returns an array of {id, threadId, labelIds, snippet?, historyId?, internalDate?, sizeEstimate?, from?, to?, cc?, bcc?, replyTo?, subject?, date?, messageId?, body, bodyTruncated, attachments={{id, filename?, mimeType?, size?, inline, contentId?}}, headers={{name,value}}}. Batches run with at most 10 requests in flight. Use metadata to scan cheaply. " .. READ_OPTIONS,
		inputSchema = input(batchReadProperties, {"ids"}, {ids = {"m1", "m2"}, format = "metadata", metadataHeaders = {"From", "Subject"}}),
		annotations = {readOnlyHint = true, openWorldHint = true},
	}
	exports.getMessages = getMessages

	reference.functions.getThread = {
		description = "Reads every message in a conversation, oldest first. Each message has the decoded shape described by getMessage. " .. READ_OPTIONS,
		inputSchema = input(readProperties, {"id"}, {id = "t1", maxBodyBytes = 4096}),
		outputSchema = object({id = ID, historyId = STRING, messages = {type = "array", items = messageSchema}}, {"messages"}, true),
		annotations = {readOnlyHint = true, openWorldHint = true},
	}
	function exports.getThread(input: any): Options
		local thread, limit, bodyFormat = read("getThread", "threads", input)
		local messages: {Options} = json.decode("[]")
		for _, raw in thread.messages or {} do table.insert(messages, message(raw, limit, bodyFormat)) end
		thread.messages = messages
		return thread
	end

	reference.functions.getAttachment = {
		description = "Streams an attachment into a session file. attachmentId comes from a message's attachments[].id. Returns path, signed Houston download url and byte size; never inline attachment bytes.",
		inputSchema = input({messageId = ID, attachmentId = ID, path = ID}, {"messageId", "attachmentId", "path"}, {messageId = "m1", attachmentId = "a1", path = "files/report.pdf"}),
		outputSchema = object({path = STRING, url = STRING, size = INTEGER}, {"path", "url", "size"}),
		annotations = {readOnlyHint = true, openWorldHint = true},
	}
	exports.getAttachment = getAttachment

	reference.functions.listMailFolders = {
		description = "Lists every mailbox label as an array of {id, name}, sorted by ID. Takes no arguments.",
		args = {}, inputSchema = input({}, {}, {}), annotations = {readOnlyHint = true, openWorldHint = true},
	}
	function exports.listMailFolders(...: any): {{id: string, name: string}}
		assert(select("#", ...) == 0, "listMailFolders takes no arguments")
		local labels = call("listMailFolders", "GET", API .. "/labels").labels or {}
		local folders: {{id: string, name: string}} = json.decode("[]")
		local seen = {}
		for _, label in labels do
			if type(label) ~= "table" or type(label.id) ~= "string" or label.id == "" or type(label.name) ~= "string" or seen[label.id] then
				houston.fail({operation = "listMailFolders", layer = "upstream", retryable = false, message = "Google returned invalid label metadata"})
			end
			seen[label.id] = true
			table.insert(folders, {id = label.id, name = label.name})
		end
		table.sort(folders, function(a: any, b: any) return a.id < b.id end)
		return folders
	end
end

if houston.allows("drafts:manage") then
	reference.functions.getDraft = {
		description = "Reads a draft with its message decoded like getMessage. " .. READ_OPTIONS .. " Long bodies stored as attachments require Messages Read access. Without it, bodyTruncated is true; auto can fall back to the snippet. Never replace a draft with incomplete content.",
		inputSchema = input(readProperties, {"id"}, {id = "d1", maxBodyBytes = 4096}),
		outputSchema = object({id = ID, message = messageSchema}, {"message"}, true), annotations = {readOnlyHint = true, openWorldHint = true},
	}
	function exports.getDraft(input: any): Options
		local draft, limit, bodyFormat = read("getDraft", "drafts", input)
		draft.message = message(draft.message or {}, limit, bodyFormat)
		return draft
	end
end

local COMPOSE = "Builds MIME from plain fields; do not encode anything yourself. to, cc, bcc and replyTo accept an address or an array. from must be a Gmail send-as address; otherwise Gmail replaces it with the mailbox address, also the default. Supply to or inReplyTo, and nonempty text and/or html. Attachments read session files. Keep the encoded message under 8 MiB (about 5 MiB of attachments); share larger files from Drive. inReplyTo is a Gmail message ID and requires Messages Read: recipients, Re: subject and threading headers default from the original. replyAll=true also copies its To/Cc except yourself; explicit cc overrides that default."
local addressSchema = {oneOf = {ID, {type = "array", items = ID, minItems = 1}} :: {Options}}
local composeProperties = {to = addressSchema, cc = addressSchema, bcc = addressSchema, replyTo = addressSchema, from = STRING,
	subject = STRING, text = ID, html = ID, inReplyTo = ID, replyAll = {type = "boolean", default = false},
	attachments = {type = "array", items = {oneOf = {ID, object({path = ID, filename = ID, mimeType = ID}, {"path"}, true)}}}}
local function composeInput(update: boolean): Options
	local properties = table.clone(composeProperties)
	local example: Options = {to = "ana@example.com", subject = "Launch plan", text = "Please review the launch plan."}
	if update then properties.id, example.id = ID, "d1" end
	local schema = input(properties, if update then {"id"} else {}, example)
	schema.allOf = {{anyOf = {{required = {"to"}}, {required = {"inReplyTo"}}}}, {anyOf = {{required = {"text"}}, {required = {"html"}}}}}
	return schema
end
if houston.allows("drafts:create") or houston.allows("sending:send") then reference.sections.composing = COMPOSE end

if houston.allows("sending:send") then
	reference.functions.sendMessage = {
		description = "Sends a new message or reply immediately. " .. COMPOSE .. " A timeout may still have sent mail: " .. (if houston.allows("messages:read") then "check SENT before retrying." else "this connection cannot read SENT; tell the person before retrying."),
		inputSchema = composeInput(false), outputSchema = messageRef, annotations = {readOnlyHint = false, openWorldHint = true},
	}
	function exports.sendMessage(input: any): any
		return submit("sendMessage", "POST", "/messages/send", options(input), false)
	end
end
if houston.allows("drafts:create") then
	reference.functions.createDraft = {
		description = "Saves a draft without sending; the person reviews and sends it from Gmail. " .. COMPOSE,
		inputSchema = composeInput(false), outputSchema = draftRef, annotations = {readOnlyHint = false, openWorldHint = true},
	}
	function exports.createDraft(input: any): any
		return submit("createDraft", "POST", "/drafts", options(input), true)
	end
end
if houston.allows("drafts:manage") then
	reference.functions.updateDraft = {
		description = "Replaces the draft's content without sending. Include every recipient, body and attachment you want to retain; never copy a truncated body. It stays in its conversation and keeps its subject when none is given; a new subject can start a new conversation, and inReplyTo moves it into that message's conversation. " .. COMPOSE,
		inputSchema = composeInput(true), outputSchema = draftRef, annotations = {readOnlyHint = false, openWorldHint = true},
	}
	function exports.updateDraft(input: any): any
		local args = options(input)
		local id = url.segment(text(args.id, "id"), "id")
		args.id = nil
		return submit("updateDraft", "PUT", "/drafts/" .. id, args, true, id)
	end
end

exports.help = reference
return exports
