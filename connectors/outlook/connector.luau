-- Microsoft Graph v1.0 for the connected account's Outlook mailbox. Arguments and results keep
-- Graph's native field names; attachments move through session files, never base64.

-- Request layer shared verbatim by the Microsoft Graph connectors; Hub runs each copy against
-- every consumer's fixtures.
type Options = {[string]: any}
type Spec = {query: {string}?, body: boolean?, list: string?, defaults: Options?, headers: HttpHeaders?}
local GRAPH = "https://graph.microsoft.com/v1.0"
-- Preauthenticated OneDrive download links, under either annotation, work without credentials,
-- so results never carry them.
local SIGNED = {"@microsoft.graph.downloadUrl", "@content.downloadUrl"}

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

local function done(name: string, args: Options)
	local unknown = next(args)
	assert(unknown == nil, name .. " received an unknown option " .. tostring(unknown))
end

-- Moves the named fields from args into a query string. A $name is an OData option taken from
-- the field without $ (select, top, ...); arrays join with commas, as OData lists do.
local function query(args: Options, names: {string}): string
	local parts: {string} = {}
	for _, name in names do
		local field = if string.sub(name, 1, 1) == "$" then string.sub(name, 2) else name
		local value = args[field]
		args[field] = nil
		if value ~= nil then
			local items: {string} = {}
			for key, item in (if type(value) == "table" then value else {value}) do
				assert(type(key) == "number" and (type(item) == "string" or type(item) == "number" or type(item) == "boolean"), field .. " must be a string, number, boolean or an array of them")
				table.insert(items, url.encode(item))
			end
			assert(#items > 0, field .. " must not be an empty array")
			table.insert(parts, (if field == name then url.encode(name) else name) .. "=" .. table.concat(items, ","))
		end
	end
	return if #parts > 0 then "?" .. table.concat(parts, "&") else ""
end

-- Graph errors are {error = {code, message, innerError?}}; Excel puts its actionable code, such as
-- invalidSessionReCreatable, in innerError.code. Throttling answers 429 or 503 with Retry-After.
-- Quota (507) and other server refusals are not transient. A write that failed with a server error
-- may still have been applied, so only a refused (429) write is retryable.
local function fail(operation: string, response: HttpResponse, write: boolean?): never
	local ok, decoded = pcall(json.decode, await(response.body:readPrefix(4096)))
	local problem = if ok and type(decoded) == "table" and type(decoded.error) == "table" then decoded.error else {}
	local status = response.statusCode
	local message = "Microsoft Graph HTTP " .. tostring(status)
	if type(problem.code) == "string" then message ..= " (" .. problem.code .. ")" end
	if type(problem.message) == "string" then message ..= ": " .. string.sub(problem.message, 1, 600) end
	local detail = problem.innerError or problem.innererror
	local inner = if type(detail) == "table" then detail.code else nil
	if type(inner) == "string" and string.lower(inner) ~= string.lower(tostring(problem.code)) and not string.match(inner, "^%d+$") then
		message ..= "; innerError: " .. inner
	end
	local retry = response.headers["retry-after"]
	if retry and retry[1] then message ..= "; Retry-After: " .. retry[1] end
	return houston.fail({operation = operation, layer = "upstream", upstream_status = status, message = message,
		retryable = status == 429 or (not write and (status == 500 or status == 502 or status == 503 or status == 504 or status == 509))})
end

local function decode(operation: string, response: HttpResponse, write: boolean?): any
	if response.statusCode < 200 or response.statusCode >= 300 then fail(operation, response, write) end
	local raw = await(response.body:readAll())
	if string.match(raw, "^%s*$") then return {success = true} end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" or not string.match(raw, "^%s*{") then
		houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode,
			retryable = false, message = "Microsoft Graph returned an invalid JSON object"})
	end
	for _, key in SIGNED do
		value[key] = nil
		for _, item in (if type(value.value) == "table" then value.value else {}) :: {any} do
			if type(item) == "table" then item[key] = nil end
		end
	end
	return value
end

local function call(operation: string, method: string, href: string, body: any?, headers: HttpHeaders?): any
	local sent: HttpHeaders = if headers then table.clone(headers) else {}
	if body ~= nil then sent["Content-Type"] = {"application/json"} end
	return decode(operation, await(http.request({method = method, url = href, headers = sent,
		body = if body ~= nil then json.encode(body) elseif method == "POST" then "" else nil})), method ~= "GET")
end

-- Streams fetch()'s response to a session file; the path changes only when the whole body arrived.
local function save(operation: string, path: string, fetch: () -> HttpResponse): Options
	local output = fs.open(path, "w")
	local ok, err = pcall(function()
		local response = fetch()
		if response.statusCode ~= 200 then fail(operation, response) end
		output:write(response.body)
		await(output:close())
	end)
	if not ok then
		output:cancel()
		pcall(function() await(output:close()) end)
		error(err, 0)
	end
	return {path = path, url = await(fs.signedGetUrl(path)), size = await(fs.stat(path)).size}
end

-- Follows an @odata.nextLink of the list whose path ends with the pattern ending. It may carry only
-- paging options and a calendar view's time range: an $expand, or another route such as
-- thumbnails, could return attachment bytes or signed links. Graph may name entities by OData
-- key, as in mailFolders('inbox'), which the routes accept in their path form, mailFolders/inbox.
local PAGING = {select = true, top = true, skip = true, skiptoken = true, orderby = true, filter = true, search = true, count = true,
	startdatetime = true, enddatetime = true}
local function pageLink(link: string, ending: string): string
	local raw, search = string.match(link, "^([^?#]*)(%??[^#]*)$")
	assert(raw and search and string.sub(raw, 1, #GRAPH + 1) == GRAPH .. "/", "nextLink must be an @odata.nextLink from Microsoft Graph")
	local path = string.gsub((string.gsub(raw, "%%27", "'")), "/(%w+)%('([^'/]+)'%)", "/%1/%2")
	assert(string.find(path, ending), "nextLink must come from the same list")
	for pair in string.gmatch(string.sub(search, 2), "[^&]+") do
		local name = string.lower((string.gsub(string.match(pair, "^[^=]*") or "", "%%(%x%x)", function(hex: string): string
			return string.char(tonumber(hex, 16) or 0)
		end)))
		assert(PAGING[(string.gsub(name, "^%$", ""))], "nextLink may carry only paging options")
	end
	return path .. search
end

-- A list's nextLink, the previous page's @odata.nextLink, replaces every other option.
local function nextLink(name: string, args: Options, ending: string): string?
	if args.nextLink == nil then return nil end
	local link = text(args.nextLink, "nextLink")
	args.nextLink = nil
	assert(next(args) == nil, name .. " takes nextLink alone, from a previous page of the same list")
	return pageLink(link, ending)
end

-- One Graph request built from args, on a path under v1.0 such as /me/events: {field} placeholders
-- take URL-encoded path segments, query names the query fields and, with body, the other fields
-- form the JSON body. A list (the Lua pattern its path ends with) also accepts nextLink and always
-- returns a value array.
local function request(name: string, method: string, path: string, input: any, spec: Spec?): any
	local args = options(input)
	local s: Spec = spec or {}
	local href = if s.list then nextLink(name, args, s.list) else nil
	if not href then
		local defaults: Options = s.defaults or {}
		for key, value in defaults do
			if args[key] == nil then args[key] = value end
		end
		local route = string.gsub(path, "{(%w+)}", function(field: string)
			local value = url.segment(text(args[field], field), field)
			args[field] = nil
			return value
		end)
		href = GRAPH .. route .. query(args, s.query or {})
		if not s.body then done(name, args) end
	end
	local result = call(name, method, href :: string, if s.body then args else nil, s.headers)
	if s.list and result.value == nil then result.value = json.decode("[]") end
	return result
end

-- An operation namespace, whose help lists the functions added to it.
local function namespace(summary: string): Options
	return {help = {text = summary, functions = {} :: {[string]: any}}}
end
-- End of the shared request layer.

-- Draft connections change only drafts, and the proxy refuses every send.
local DRAFTS = access.data == "draft"
local LIST = "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,isRead,isDraft,hasAttachments,importance,flag,categories,conversationId,parentFolderId,bodyPreview,webLink"
-- Graph refuses requests over 4 MB, and base64 makes attachments a third larger.
local MAX_REQUEST = 4000000
local MAX_ATTACHMENTS = 2900000

local help = {
	text = [[Microsoft Graph v1.0 for the connected Outlook mailbox. Operations take one named options object
with Graph's camelCase fields and return Graph's JSON unchanged; sends and deletes return
{success=true}. Connector calls return completed values: use them directly, without await.
Messages carry decoded bodies; attachments save to session files, and composing reads attachments
from session paths: never base64-encode anything yourself. Moving a message gives it a new id.
Lists return one page: while ['@odata.nextLink'] is present, pass it back as nextLink (alone, with
bodyFormat or maxBodyBytes if used). listMailFolders alone walks the whole folder tree.
Houston itself retries only a short 429 wait. Errors report the HTTP status and Graph's code and
message, e.g. 'Microsoft Graph HTTP 404 (ErrorItemNotFound)'; 429 is retryable, and so are
503 and other transient server errors on reads. A failed or timed-out write may already have succeeded: check Sent Items or
Drafts before repeating.]] .. (if DRAFTS then "\nDraft connection: Houston refuses every send, and changes apply only to drafts. Save drafts for the person to review and send from Outlook." else ""),
	functions = {} :: {[string]: any},
}
-- Draft and Write connections compose; only Write sends.
local COMPOSES = houston.allows("data:draft")
local SENDS = houston.allows("data:write")
local messages = namespace(if SENDS then "Read, search, send, reply to, forward, move and change messages and drafts."
	elseif COMPOSES then "Read and search messages; create, change and delete drafts, replies and forwards." else "Read and search messages.")
local attachments = namespace(if COMPOSES then "Save message attachments to session files, and attach session files to drafts."
	else "Save message attachments to session files.")
local folders = namespace((if SENDS then "Read and create mail folders" else "Read a mail folder")
	.. "; the root listMailFolders lists every folder.")
local exports: {[string]: any} = {help = help, messages = messages, attachments = attachments, folders = folders}

-- Schemas and hints shared by several operations.
local ID = {type = "string", minLength = 1}
local MESSAGE_ID = "AAMkAGI2THVSAAA="
local SELECT = {type = {"string", "array"}, items = {type = "string"}, description = "Message fields, comma-separated or as an array."}
local NEXT = {type = "string", description = "The previous page's @odata.nextLink; pass it alone, with bodyFormat or maxBodyBytes if used."}
local BODY_FORMAT = {type = "string", enum = {"text", "html"}, description = "Format of body and uniqueBody; defaults to text."}
local MAX_BODY = {type = "integer", minimum = 0, description = "Caps body and uniqueBody content in bytes and sets bodyTruncated; defaults to 65536, 0 for no cap."}
local RECIPIENTS = {
	type = "array",
	items = {
		type = "object",
		properties = {emailAddress = {type = "object", properties = {address = ID, name = {type = "string"}}, required = {"address"}}},
		required = {"emailAddress"},
	},
}
local ATTACHMENTS = {
	type = "array",
	minItems = 1,
	items = {anyOf = {
		{type = "string", minLength = 1},
		{type = "object", properties = {path = ID, name = ID, contentType = ID}, required = {"path"}, additionalProperties = false},
	} :: {any}},
	description = "Session files to attach, about 2.9 MB in total; share larger files from OneDrive.",
}
local MESSAGE = {
	type = "object",
	properties = {
		subject = {type = "string"},
		body = {type = "object", properties = {contentType = {type = "string", description = "Text or HTML."}, content = {type = "string"}}, required = {"content"}},
		toRecipients = RECIPIENTS, ccRecipients = RECIPIENTS, bccRecipients = RECIPIENTS, replyTo = RECIPIENTS,
		importance = {type = "string", enum = {"low", "normal", "high"}},
		attachments = ATTACHMENTS,
	},
	additionalProperties = true,
	description = "Graph message fields; attachments are session files.",
}
local READ = {readOnlyHint = true, openWorldHint = true}
local WRITE = {readOnlyHint = false, destructiveHint = false, openWorldHint = true}
local DESTRUCTIVE = {readOnlyHint = false, destructiveHint = true, openWorldHint = true}

-- Prefer selects the body format; Graph defaults to HTML.
local function bodyFormat(args: Options): HttpHeaders
	local format = if args.bodyFormat == nil then "text" else args.bodyFormat
	args.bodyFormat = nil
	assert(format == "text" or format == "html", "bodyFormat must be text or html")
	return {Prefer = {"outlook.body-content-type=\"" .. format .. "\""}}
end

local function messagePath(id: any, field: string): string
	return GRAPH .. "/me/messages/" .. url.segment(text(id, field), field)
end

-- Draft connections change a message only while it is a draft, and never set extended
-- MAPI properties, which could make a draft look sent or received.
local function draftOnly(operation: string, id: any)
	if not DRAFTS then return end
	local message = call(operation, "GET", messagePath(id, "id") .. "?$select=isDraft")
	assert(message.isDraft == true, operation .. " changes only drafts on a Draft connection")
end

local function plain(fields: Options)
	if not DRAFTS then return end
	for key in fields do
		assert(not string.find(string.lower(key), "extendedproperties", 1, true), "Draft connections cannot set extended properties")
	end
end

-- Session files become fileAttachments.
local function fileAttachments(items: any): {Options}
	assert(type(items) == "table" and items[1] ~= nil, "attachments must be an array of paths or {path, name?, contentType?}")
	local list: {Options} = json.decode("[]")
	local total = 0
	for _, entry in items do
		local spec = if type(entry) == "string" then {path = entry} else entry
		assert(type(spec) == "table", "attachments must be paths or {path, name?, contentType?}")
		local path = text(spec.path, "attachment path")
		total += await(fs.stat(path)).size
		assert(total <= MAX_ATTACHMENTS, "attachments must stay under about 2.9 MB in total; share larger files from OneDrive")
		local file = fs.open(path, "r")
		local data = await(file:readAll())
		await(file:close())
		table.insert(list, {["@odata.type"] = "#microsoft.graph.fileAttachment", name = text(spec.name or string.match(path, "[^/]+$"), "attachment name"),
			contentType = if spec.contentType == nil then nil else text(spec.contentType, "attachment contentType"), contentBytes = base64.encode(data)})
	end
	return list
end

-- A message resource with its attachments read from session files. The encoded attachments and the
-- rest of the message must fit in Graph's 4 MB request.
local function compose(value: any, field: string): Options
	local message = options(value)
	plain(message)
	if message.attachments ~= nil then
		local files = fileAttachments(message.attachments)
		message.attachments = nil
		local size = #json.encode(message)
		for _, attachment in files do size += #attachment.contentBytes + #attachment.name + 128 end
		message.attachments = files
		assert(size <= MAX_REQUEST, "the message and its attachments must stay under 4 MB; share larger files from OneDrive")
	end
	return message
end

-- Caps body.content and uniqueBody.content at maxBodyBytes without splitting a UTF-8 sequence, and
-- reports it in bodyTruncated.
local function limitBody(message: any, limit: number)
	if type(message) ~= "table" then return end
	for _, field in {"body", "uniqueBody"} do
		local body = message[field]
		if type(body) == "table" and type(body.content) == "string" then
			local content = body.content
			message.bodyTruncated = message.bodyTruncated == true or (limit > 0 and #content > limit)
			if limit > 0 and #content > limit then
				local start = limit
				while start > 1 and start > limit - 3 and string.byte(content, start) // 64 == 2 do start -= 1 end
				local lead = string.byte(content, start)
				local size = if lead >= 240 then 4 elseif lead >= 224 then 3 elseif lead >= 192 then 2 else 1
				body.content = string.sub(content, 1, if start + size - 1 > limit then start - 1 else limit)
			end
		end
	end
end

local function bodyLimit(args: Options): number
	local limit = if args.maxBodyBytes == nil then 65536 else args.maxBodyBytes
	args.maxBodyBytes = nil
	assert(type(limit) == "number" and limit >= 0 and limit % 1 == 0, "maxBodyBytes must be a nonnegative integer")
	return limit
end

-- Replies and forwards take a message whose attachments are session files, like messages.createDraft.
local function respond(verb: string, input: any): Options
	local args = options(input)
	if args.message ~= nil then args.message = compose(args.message, "message") end
	return request("messages." .. verb, "POST", "/me/messages/{id}/" .. verb, args, {body = true})
end

local function replySchema(forward: boolean, example: Options): Options
	local properties: Options = {id = ID, comment = {type = "string", description = "Text above the quoted original."}, message = MESSAGE}
	if forward then properties.toRecipients = RECIPIENTS end
	return {type = "object", properties = properties, required = if forward then {"id", "toRecipients"} else {"id"}, additionalProperties = false, examples = {example}}
end

help.functions.getProfile = {
	description = "The connected account: {id, displayName, mail, userPrincipalName}.",
	inputSchema = {type = "object", properties = {select = SELECT}, additionalProperties = false, examples = {{select = "displayName,mail"}}},
	annotations = READ,
}
function exports.getProfile(args: Options?): Options
	return request("getProfile", "GET", "/me", args, {defaults = {select = "id,displayName,mail,userPrincipalName"}, query = {"$select"}})
end

-- Fixed-signature folder list shared with other mail connectors.
help.functions.listMailFolders = {
	description = "Every visible folder of the mailbox as {{id, name}} sorted by ID, nested names joined with '/' such as 'Inbox/Projects'.",
	args = {},
	inputSchema = {type = "object", properties = {}, additionalProperties = false, examples = {json.decode("{}")}},
	annotations = READ,
}
function exports.listMailFolders(...: any): {{id: string, name: string}}
	assert(select("#", ...) == 0, "listMailFolders takes no arguments")
	local FIELDS = "?$top=100&$select=id,displayName,childFolderCount"
	local found: {{id: string, name: string}} = json.decode("[]")
	local seen: {[string]: boolean} = {}
	local pending: {{href: string, prefix: string}} = {{href = GRAPH .. "/me/mailFolders" .. FIELDS, prefix = ""}}
	while #pending > 0 do
		local job = table.remove(pending) :: {href: string, prefix: string}
		local page = call("listMailFolders", "GET", job.href)
		local items: {any} = if type(page.value) == "table" then page.value else {}
		for _, folder in items do
			if type(folder) ~= "table" or type(folder.id) ~= "string" or folder.id == "" or type(folder.displayName) ~= "string" then
				houston.fail({operation = "listMailFolders", layer = "upstream", retryable = false, message = "Microsoft Graph returned invalid folder metadata"})
			end
			-- $skip paging can repeat a folder when the mailbox changes between pages.
			if not seen[folder.id] then
				seen[folder.id] = true
				local name = job.prefix .. folder.displayName
				table.insert(found, {id = folder.id, name = name})
				if type(folder.childFolderCount) == "number" and folder.childFolderCount > 0 then
					table.insert(pending, {href = GRAPH .. "/me/mailFolders/" .. url.segment(folder.id, "folder ID") .. "/childFolders" .. FIELDS, prefix = name .. "/"})
				end
			end
		end
		local link = page["@odata.nextLink"]
		if type(link) == "string" then table.insert(pending, {href = pageLink(link, "/%l+Folders$"), prefix = job.prefix}) end
	end
	table.sort(found, function(a: any, b: any) return a.id < b.id end)
	return found
end

folders.help.functions.get = {
	description = "One folder: {id, displayName, parentFolderId, childFolderCount, unreadItemCount, totalItemCount}. id is a folder ID or a well-known name: inbox, drafts, sentitems, deleteditems, archive, junkemail.",
	inputSchema = {type = "object", properties = {id = ID, select = SELECT}, required = {"id"}, additionalProperties = false, examples = {{id = "inbox"}}},
	annotations = READ,
}
function folders.get(args: Options?): Options
	return request("folders.get", "GET", "/me/mailFolders/{id}", args, {query = {"$select"}})
end

messages.help.functions.list = {
	description = [[One page of messages, from every folder or from folderId (an ID or well-known name such as
'inbox'): {value={message}, ['@odata.nextLink']?}. search is KQL, e.g. 'from:ana budget' or
'subject:invoice hasAttachments:true', returns at most 1000 messages and cannot combine with
filter, orderby or skip. filter is OData, e.g. "receivedDateTime ge 2026-10-01T00:00:00Z and
isRead eq false"; with orderby, the ordered fields must also lead filter (Graph answers
InefficientFilter otherwise). top is at most 1000 (default 10). Default fields: ]] .. LIST .. [[;
add body to select for full bodies. A conversation is filter="conversationId eq '<id>'".]],
	inputSchema = {
		type = "object",
		properties = {
			folderId = ID, search = {type = "string", minLength = 1}, filter = {type = "string"}, orderby = {type = "string"},
			select = SELECT, top = {type = "integer", minimum = 1, maximum = 1000}, skip = {type = "integer", minimum = 0},
			bodyFormat = BODY_FORMAT, maxBodyBytes = MAX_BODY, nextLink = NEXT,
		},
		additionalProperties = false,
		examples = {{folderId = "inbox", filter = "isRead eq false", top = 20}, {search = "from:ana budget", top = 10}} :: {any},
	},
	annotations = READ,
}
function messages.list(input: any): Options
	local args = options(input)
	local headers = bodyFormat(args)
	local limit = bodyLimit(args)
	local link = nextLink("messages.list", args, "/messages$")
	local href = GRAPH .. "/me/messages"
	if not link then
		if args.folderId ~= nil then href = GRAPH .. "/me/mailFolders/" .. url.segment(text(args.folderId, "folderId"), "folderId") .. "/messages" end
		args.folderId = nil
		if args.select == nil then args.select = LIST end
		-- $search takes a quoted string; \ and " inside it are escaped.
		if args.search ~= nil then args.search = "\"" .. (string.gsub(text(args.search, "search"), "[\\\"]", "\\%0")) .. "\"" end
		href ..= query(args, {"$select", "$filter", "$search", "$orderby", "$top", "$skip"})
		done("messages.list", args)
	end
	local page = call("messages.list", "GET", link or href, nil, headers)
	if page.value == nil then page.value = json.decode("[]") end
	for _, message in page.value do limitBody(message, limit) end
	return page
end

messages.help.functions.get = {
	description = [[One message with every field unless select narrows them: {id, subject, from, toRecipients,
ccRecipients, bccRecipients, replyTo, receivedDateTime, body={contentType, content}, bodyTruncated,
uniqueBody?, isRead, isDraft, hasAttachments, conversationId, internetMessageId, webLink, ...}.]],
	inputSchema = {
		type = "object",
		properties = {id = ID, select = SELECT, bodyFormat = BODY_FORMAT, maxBodyBytes = MAX_BODY},
		required = {"id"},
		additionalProperties = false,
		examples = {{id = MESSAGE_ID}, {id = MESSAGE_ID, bodyFormat = "html", maxBodyBytes = 0}} :: {any},
	},
	annotations = READ,
}
function messages.get(input: any): Options
	local args = options(input)
	local headers = bodyFormat(args)
	local limit = bodyLimit(args)
	local href = messagePath(args.id, "id")
	args.id = nil
	href ..= query(args, {"$select"})
	done("messages.get", args)
	local message = call("messages.get", "GET", href, nil, headers)
	limitBody(message, limit)
	return message
end

attachments.help.functions.list = {
	description = "A message's attachments as metadata, {value={{id, name, contentType, size, isInline}}}; save one with attachments.get.",
	inputSchema = {type = "object", properties = {messageId = ID, select = SELECT, nextLink = NEXT}, additionalProperties = false, examples = {{messageId = MESSAGE_ID}}},
	annotations = READ,
}
function attachments.list(args: Options?): Options
	local page = request("attachments.list", "GET", "/me/messages/{messageId}/attachments", args,
		{list = "/attachments$", defaults = {select = "id,name,contentType,size,isInline,lastModifiedDateTime"}, query = {"$select"}})
	-- Attachment bytes move through attachments.get, never inline, whatever select asks for.
	for _, attachment in page.value do
		if type(attachment) == "table" then attachment.contentBytes = nil end
	end
	return page
end

attachments.help.functions.get = {
	description = "Saves an attachment's bytes to a session path (an attached message saves as MIME) and returns {path, url, size}; url is a signed Houston download link.",
	inputSchema = {
		type = "object",
		properties = {messageId = ID, attachmentId = ID, path = {type = "string", minLength = 1, description = "Session file path to write."}},
		required = {"messageId", "attachmentId", "path"},
		additionalProperties = false,
		examples = {{messageId = MESSAGE_ID, attachmentId = "AAMkAGI2THVSAAABEgAQAA=", path = "invoice.pdf"}},
	},
	annotations = READ,
}
function attachments.get(input: any): Options
	local args = options(input)
	local href = messagePath(args.messageId, "messageId") .. "/attachments/" .. url.segment(text(args.attachmentId, "attachmentId"), "attachmentId") .. "/$value"
	local path = text(args.path, "path")
	args.messageId, args.attachmentId, args.path = nil, nil, nil
	done("attachments.get", args)
	return save("attachments.get", path, function(): HttpResponse return await(http.request({method = "GET", url = href})) end)
end

if COMPOSES then
	messages.help.functions.createDraft = {
		description = "Saves a message to Drafts without sending and returns the draft" .. (if DRAFTS then "; the person reviews and sends it from Outlook." else "; send it with messages.sendDraft."),
		inputSchema = {
			type = "object",
			properties = MESSAGE.properties,
			additionalProperties = true,
			examples = {{subject = "Q3 report", body = {contentType = "Text", content = "Report attached."},
				toRecipients = {{emailAddress = {address = "ana@example.com"}}}, attachments = {"report.pdf"}}},
		},
		annotations = WRITE,
	}
	function messages.createDraft(input: any): Options
		return call("messages.createDraft", "POST", GRAPH .. "/me/messages", compose(input, "messages.createDraft options"))
	end

	messages.help.functions.createReply = {
		description = "Creates a reply draft addressed to the sender, in the conversation, and returns it; edit it with messages.update.",
		inputSchema = replySchema(false, {id = MESSAGE_ID, comment = "Thanks, I'll review it today."}),
		annotations = WRITE,
	}
	function messages.createReply(input: any): Options
		return respond("createReply", input)
	end

	messages.help.functions.createReplyAll = {
		description = "Creates a reply draft addressed to every recipient and returns it.",
		inputSchema = replySchema(false, {id = MESSAGE_ID, comment = "Thanks all."}),
		annotations = WRITE,
	}
	function messages.createReplyAll(input: any): Options
		return respond("createReplyAll", input)
	end

	messages.help.functions.createForward = {
		description = "Creates a forward draft, with the original's attachments, and returns it.",
		inputSchema = {
			type = "object",
			properties = {id = ID, toRecipients = RECIPIENTS, comment = {type = "string"}, message = MESSAGE},
			required = {"id"},
			additionalProperties = false,
			examples = {{id = MESSAGE_ID, toRecipients = {{emailAddress = {address = "bo@example.com"}}}, comment = "FYI"}},
		},
		annotations = WRITE,
	}
	function messages.createForward(input: any): Options
		return respond("createForward", input)
	end

	messages.help.functions.update = {
		description = if DRAFTS then "Changes a draft's fields, such as subject, body or recipients, and returns it."
			else "Changes a message: isRead, categories, flag={flagStatus='flagged'|'complete'|'notFlagged'} or importance; drafts also take subject, body and recipients. Returns the message.",
		inputSchema = {
			type = "object",
			properties = {id = ID, isRead = {type = "boolean"}, categories = {type = "array", items = {type = "string"}}, flag = {type = "object"}, subject = {type = "string"}, body = MESSAGE.properties.body},
			required = {"id"},
			minProperties = 2,
			additionalProperties = true,
			examples = {if DRAFTS then {id = MESSAGE_ID, subject = "Q3 report (v2)"} else {id = MESSAGE_ID, isRead = true}},
		},
		annotations = WRITE,
	}
	function messages.update(input: any): Options
		local args = options(input)
		local id = text(args.id, "id")
		args.id = nil
		assert(next(args) ~= nil and args.attachments == nil, "messages.update requires fields to change; add attachments with attachments.add")
		plain(args)
		draftOnly("messages.update", id)
		return call("messages.update", "PATCH", messagePath(id, "id"), args)
	end

	messages.help.functions.delete = {
		description = "Deletes " .. (if DRAFTS then "a draft" else "a message") .. " and returns {success=true}. It stays recoverable for the mailbox's retention period but does not appear in Deleted Items; to trash a message instead, move it to 'deleteditems'.",
		inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false, examples = {{id = MESSAGE_ID}}},
		annotations = DESTRUCTIVE,
	}
	function messages.delete(input: any): Options
		local args = options(input)
		local id = text(args.id, "id")
		args.id = nil
		done("messages.delete", args)
		draftOnly("messages.delete", id)
		return call("messages.delete", "DELETE", messagePath(id, "id"))
	end

	attachments.help.functions.add = {
		description = "Attaches a session file of up to about 2.9 MB to a draft and returns the attachment {id, name, size}.",
		inputSchema = {
			type = "object",
			properties = {messageId = ID, path = ID, name = ID, contentType = ID},
			required = {"messageId", "path"},
			additionalProperties = false,
			examples = {{messageId = MESSAGE_ID, path = "report.pdf", contentType = "application/pdf"}},
		},
		annotations = WRITE,
	}
	function attachments.add(input: any): Options
		local args = options(input)
		local id = text(args.messageId, "messageId")
		local spec = {path = args.path, name = args.name, contentType = args.contentType}
		args.messageId, args.path, args.name, args.contentType = nil, nil, nil, nil
		done("attachments.add", args)
		draftOnly("attachments.add", id)
		return call("attachments.add", "POST", messagePath(id, "messageId") .. "/attachments", fileAttachments({spec})[1])
	end
end

if SENDS then
	messages.help.functions.send = {
		description = "Sends a message immediately and returns {success=true}. saveToSentItems defaults to true. A timeout may still have sent the mail: check Sent Items before retrying.",
		inputSchema = {
			type = "object",
			properties = {message = MESSAGE, saveToSentItems = {type = "boolean"}},
			required = {"message"},
			additionalProperties = false,
			examples = {{message = {subject = "Lunch?", body = {contentType = "Text", content = "Noon at the usual place?"},
				toRecipients = {{emailAddress = {address = "ana@example.com", name = "Ana"}}}}}},
		},
		annotations = WRITE,
	}
	function messages.send(input: any): Options
		local args = options(input)
		assert(type(args.message) == "table" and next(args.message) ~= nil, "messages.send requires a nonempty message")
		local body = {message = compose(args.message, "message"), saveToSentItems = args.saveToSentItems}
		args.message, args.saveToSentItems = nil, nil
		done("messages.send", args)
		return call("messages.send", "POST", GRAPH .. "/me/sendMail", body)
	end

	messages.help.functions.sendDraft = {
		description = "Sends a draft and returns {success=true}; the sent copy gets a new ID in Sent Items.",
		inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false, examples = {{id = MESSAGE_ID}}},
		annotations = WRITE,
	}
	function messages.sendDraft(args: Options?): Options
		return request("messages.sendDraft", "POST", "/me/messages/{id}/send", args)
	end

	messages.help.functions.reply = {
		description = "Sends a reply to the sender and returns {success=true}.",
		inputSchema = replySchema(false, {id = MESSAGE_ID, comment = "On it."}),
		annotations = WRITE,
	}
	function messages.reply(input: any): Options
		return respond("reply", input)
	end

	messages.help.functions.replyAll = {
		description = "Sends a reply to every recipient and returns {success=true}.",
		inputSchema = replySchema(false, {id = MESSAGE_ID, comment = "Thanks all."}),
		annotations = WRITE,
	}
	function messages.replyAll(input: any): Options
		return respond("replyAll", input)
	end

	messages.help.functions.forward = {
		description = "Forwards the message to toRecipients and returns {success=true}.",
		inputSchema = replySchema(true, {id = MESSAGE_ID, toRecipients = {{emailAddress = {address = "bo@example.com"}}}, comment = "FYI"}),
		annotations = WRITE,
	}
	function messages.forward(input: any): Options
		return respond("forward", input)
	end

	messages.help.functions.move = {
		description = "Moves a message and returns it with its new id. destinationId is a folder ID or a well-known name; 'deleteditems' trashes and 'archive' archives.",
		inputSchema = {type = "object", properties = {id = ID, destinationId = ID}, required = {"id", "destinationId"}, additionalProperties = false, examples = {{id = MESSAGE_ID, destinationId = "archive"}}},
		annotations = WRITE,
	}
	function messages.move(args: Options?): Options
		return request("messages.move", "POST", "/me/messages/{id}/move", args, {body = true})
	end

	folders.help.functions.create = {
		description = "Creates a top-level folder, or a child of parentId, and returns it.",
		inputSchema = {type = "object", properties = {displayName = ID, parentId = ID}, required = {"displayName"}, additionalProperties = false, examples = {{displayName = "Clients"}}},
		annotations = WRITE,
	}
	function folders.create(input: any): Options
		local args = options(input)
		local href = GRAPH .. "/me/mailFolders" .. (if args.parentId == nil then "" else "/" .. url.segment(text(args.parentId, "parentId"), "parentId") .. "/childFolders")
		args.parentId = nil
		text(args.displayName, "displayName")
		return call("folders.create", "POST", href, args)
	end
end

return exports
