-- Microsoft Graph v1.0 for the SharePoint sites, document libraries, lists and pages the connected
-- account can open. Arguments and results keep Graph's native field names.
-- Request layer shared verbatim by the Microsoft Graph connectors; Hub runs each copy against
-- every consumer's fixtures.
type Options = {[string]: any}
type Spec = {query: {string}?, body: boolean?, list: string?, defaults: Options?, headers: HttpHeaders?}
local GRAPH = "https://graph.microsoft.com/v1.0"
-- When SharePoint Online throttles, it serves traffic identified in Microsoft's ISV format first.
local USER_AGENT = "ISV|AIBakery|Houston/1.0"
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

-- Headers for every request to Graph or its download hosts, with the extra ones given.
local function identified(extra: HttpHeaders?): HttpHeaders
	local sent: HttpHeaders = if extra then table.clone(extra) else {}
	sent["User-Agent"] = {USER_AGENT}
	return sent
end

-- A request other than GET counts as a write unless write says otherwise, as for a search POST.
local function call(operation: string, method: string, href: string, body: any?, headers: HttpHeaders?, write: boolean?): any
	local sent = identified(headers)
	if body ~= nil then sent["Content-Type"] = {"application/json"} end
	return decode(operation, await(http.request({method = method, url = href, headers = sent,
		body = if body ~= nil then json.encode(body) elseif method == "POST" then "" else nil})), if write == nil then method ~= "GET" else write)
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
local function unescape(value: string): string
	return (string.gsub(value, "%%(%x%x)", function(hex: string): string return string.char(tonumber(hex, 16) or 0) end))
end

local PAGING = {select = true, top = true, skip = true, skiptoken = true, orderby = true, filter = true, search = true, count = true,
	startdatetime = true, enddatetime = true}
local function pageLink(link: string, ending: string): string
	local raw, search = string.match(link, "^([^?#]*)(%??[^#]*)$")
	assert(raw and search and string.sub(raw, 1, #GRAPH + 1) == GRAPH .. "/", "nextLink must be an @odata.nextLink from Microsoft Graph")
	local path = string.gsub((string.gsub(raw, "%%27", "'")), "/(%w+)%('([^'/]+)'%)", "/%1/%2")
	assert(string.find(path, ending), "nextLink must come from the same list")
	for pair in string.gmatch(string.sub(search, 2), "[^&]+") do
		local name = string.lower(unescape(string.match(pair, "^[^=]*") or ""))
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

local ITEM = "id,name,size,file,folder,package,parentReference,createdDateTime,lastModifiedDateTime,webUrl"
local SITE = "id,displayName,name,webUrl,description,lastModifiedDateTime"
local DRIVE = "id,name,driveType,webUrl"
local LIST = "id,name,displayName,description,webUrl,list,lastModifiedDateTime"
local MAX_UPLOAD = 250 * 1024 * 1024
-- Without this header, Graph refuses to filter or sort list items on a column that is not indexed,
-- even in small lists; lists over 5,000 items still refuse it.
local UNINDEXED: HttpHeaders = {Prefer = {"HonorNonIndexedQueriesWarningMayFailRandomly"}}
-- File content redirects to a short-lived preauthenticated URL on these hosts, fetched without credentials.
local DOWNLOAD_HOSTS = {"%.sharepoint%.com$", "%.svc%.ms$"}
-- Microsoft Search's SharePoint and OneDrive entity types; mail, events and people stay out of reach.
local ENTITY_TYPES = {driveItem = true, listItem = true, list = true, site = true, drive = true}

local WRITES = houston.allows("data:write")
local help = {
	text = [[Microsoft Graph v1.0 for the SharePoint sites, document libraries, lists and pages the connected work
or school account can open, OneDrive files included. Operations take one named options object with
Graph's camelCase fields and return Graph's JSON unchanged; deletes and copies return {success=true}.
Connector calls return completed values: use them directly, without await.
Find content with search (Microsoft Search across every site, files shared with the user included) or
sites.search, then browse: a site's document libraries are drives (files.listDrives), its lists hold
rows (lists.listItems) and its pages hold intranet content (pages.get).
A siteId is the 'host,siteCollectionId,webId' id that sites return, 'root', or a hostname for its root
site; sites.get also finds a site by webUrl. A driveId ('b!…') and an itemId travel together: item ids
are unique within their drive. A listId is the list's GUID or display name.
Lists return one page: while ['@odata.nextLink'] is present, pass it back as nextLink, alone; search
pages with from and size instead.
Files move through session paths: downloads save to a path and return a signed Houston URL, uploads
read from a path. Never inline file bytes. Results omit preauthenticated download links.
No hidden paging; Houston itself retries only a short 429 wait. SharePoint throttles per user and per
app: on 429 or 503, wait for Retry-After. Errors report the HTTP status and Graph's code and message,
e.g. 'Microsoft Graph HTTP 404 (itemNotFound)'; 429 is retryable, and so are 503 and other transient
server errors on reads. A failed or timed-out write may already have succeeded: check before repeating.]],
	functions = {} :: {[string]: any},
}
local sites = namespace("Find sites by search, URL or following, and list their subsites.")
local files = namespace((if WRITES then "Browse, search, download, upload, change, copy and delete" else "Browse, search and download")
	.. " files and folders in sites' document libraries, addressed by driveId and itemId or path.")
local lists = namespace((if WRITES then "Read lists, their columns and items; create, change and delete items." else "Read lists, their columns and items."))
local pages = namespace("Read a site's modern pages with their sections and web parts.")
local exports: {[string]: any} = {help = help, sites = sites, files = files, lists = lists, pages = pages}

-- Schemas and hints shared by several operations.
local ID = {type = "string", minLength = 1}
local SITE_ID = {type = "string", minLength = 1, description = "A site's id ('host,siteCollectionId,webId'), 'root', or a hostname for its root site."}
local DRIVE_ID = {type = "string", minLength = 1, description = "A document library's id, from files.listDrives or an item's parentReference.driveId."}
local LIST_ID = {type = "string", minLength = 1, description = "The list's GUID or display name."}
local NEXT = {type = "string", description = "The previous page's @odata.nextLink; pass it alone."}
local TOP = {type = "integer", minimum = 1, maximum = 999}
local CONFLICT = {type = "string", enum = {"rename", "replace", "fail"}, description = "What happens when the name exists."}
local REFERENCE = {type = "object", properties = {id = ID, driveId = ID}, required = {"id"}, description = "The destination folder."}
local FIELDS = {type = {"string", "array"}, items = {type = "string", pattern = "^[A-Za-z0-9_]+$"}, minItems = 1,
	description = "Internal column names, comma-separated or as an array, such as Title or Project_x0020_Name; all columns by default."}
local VALUES = {type = "object", minProperties = 1, description = "Column values keyed by internal column name."}
local READ = {readOnlyHint = true, openWorldHint = true}
local WRITE = {readOnlyHint = false, destructiveHint = false, openWorldHint = true}
local DESTRUCTIVE = {readOnlyHint = false, destructiveHint = true, openWorldHint = true}
local SITE_EXAMPLE = "contoso.sharepoint.com,2c3f5e86-9b5e-4b8a-a2a5-4e3c1d5a7b90,712a596e-90a1-49e3-9b48-bfa80bee8740"
local DRIVE_EXAMPLE = "b!hl4_LF6bikuipU48HVp7kG5ZKnGhkONJm0i_qAvuh0Cq3Fx9-dnMRKZD9-NUs2t9"
local ITEM_EXAMPLE = "01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K"
local LIST_EXAMPLE = "2a7d3b2e-5f1c-4c9e-8d3a-6b1f0e9c4d21"

local function selected(default: string): Options
	return {type = {"string", "array"}, items = {type = "string"}, description = "Fields, comma-separated or as an array; defaults to " .. default .. "."}
end

-- query() for a URL that already carries a query string.
local function more(args: Options, names: {string}): string
	local rest = query(args, names)
	return if rest == "" then "" else "&" .. string.sub(rest, 2)
end

-- A nextLink's whole path, after Graph's own prefix, so a link cannot reach another route through
-- the proxy's path-addressed rules.
local function ending(path: string): string
	return "^https://graph%.microsoft%.com/v1%.0" .. path .. "$"
end

local function sitePath(siteId: any): string
	return "/sites/" .. url.segment(text(siteId, "siteId"), "siteId")
end

-- A site URL's site: /sites/<name>, /teams/<name> and a OneDrive's /personal/<name> name one; any other
-- URL on the host, such as a page or a document, belongs to the host's root site. A URL cannot tell a
-- subsite from a folder, so subsites resolve to their parent site.
local function siteByUrl(webUrl: string): string
	local host = string.match(webUrl, "^https://([%w%.%-]+)") or ""
	local rest = string.sub(webUrl, #"https://" + #host + 1)
	assert(string.find(string.lower(host), "%.sharepoint%.com$") and (rest == "" or string.find(rest, "^[/?#]")),
		"webUrl must be an https:// URL on a sharepoint.com host")
	host = string.lower(host)
	local kind = string.lower(string.match(rest, "^/(%a+)/") or "")
	local name = string.match(rest, "^/%a+/([^/?#]+)") or ""
	if (kind ~= "sites" and kind ~= "teams" and kind ~= "personal") or name == "" then return "/sites/" .. host end
	assert(string.match(name, "^[%w_%-][%w_%-%.]*$"), "webUrl's site name may contain only letters, digits, '-', '_' and '.'")
	return "/sites/" .. host .. ":/" .. kind .. "/" .. name
end


local function listPath(siteId: any, listId: any): string
	return sitePath(siteId) .. "/lists/" .. url.segment(text(listId, "listId"), "listId")
end

-- A document library item by ID, or its root folder when id is nil.
local function itemPath(driveId: any, id: any, field: string): string
	local drive = "/drives/" .. url.segment(text(driveId, "driveId"), "driveId")
	if id == nil then return drive .. "/root" end
	return drive .. "/items/" .. url.segment(text(id, field), field)
end

-- SharePoint names cannot contain a colon, which would end path-based addressing early.
local function itemName(value: any, field: string): string
	assert(not string.find(text(value, field), ":", 1, true), field .. " cannot contain ':'")
	return url.segment(value, field)
end

local function conflictBehavior(value: any, default: string): string
	local behavior = if value == nil then default else value
	assert(behavior == "rename" or behavior == "replace" or behavior == "fail", "conflictBehavior must be rename, replace or fail")
	return behavior
end

-- One page of driveItems with the default fields, unless args holds a nextLink.
local function page(operation: string, href: string, ending: string, args: Options, names: {string}): Options
	local link = nextLink(operation, args, ending)
	if not link then
		if args.select == nil then args.select = ITEM end
		href ..= query(args, names)
		done(operation, args)
	end
	local result = call(operation, "GET", link or href)
	if result.value == nil then result.value = json.decode("[]") end
	return result
end

local function allowedDownload(location: string): boolean
	local host = string.match(location, "^https://([%w%.%-]+)[/?]")
	if host == nil then return false end
	host = string.lower(host)
	for _, pattern in DOWNLOAD_HOSTS do
		if string.find(host, pattern) then return true end
	end
	return false
end

-- The $expand of a list item's fields, narrowed to the given internal column names.
local function expandFields(value: any): string
	if value == nil then return "fields" end
	local names: {string} = {}
	if type(value) == "string" then
		for name in string.gmatch(value, "[^,%s]+") do table.insert(names, name) end
	else
		assert(type(value) == "table", "fields must be a string or an array of column names")
		for key, name in value do
			assert(type(key) == "number" and type(name) == "string", "fields must be a string or an array of column names")
			table.insert(names, name)
		end
	end
	assert(#names > 0, "fields must name at least one column")
	for _, name in names do
		assert(string.match(name, "^[%w_]+$"), "fields must be internal column names, such as Title or Project_x0020_Name")
	end
	return "fields(select=" .. table.concat(names, ",") .. ")"
end

-- Item pages keep the first page's $expand of fields, which the shared paging check refuses: it is
-- taken out, checked, and put back on the checked link.
local function itemsLink(link: string): string
	local base, search = string.match(link, "^([^?#]*)%??([^#]*)$")
	assert(base and search, "nextLink must be an @odata.nextLink from Microsoft Graph")
	local kept: {string} = {}
	local expand: string? = nil
	for pair in string.gmatch(search, "[^&]+") do
		local name, value = string.match(pair, "^([^=]*)=?(.*)$")
		if string.match(string.lower(unescape(name or "")), "^%$?expand$") then
			local fields = unescape(value or "")
			assert(expand == nil and (fields == "fields" or string.match(fields, "^fields%(%$?select=[%w_,]+%)$")),
				"nextLink may expand only the items' fields")
			expand = pair
		else
			table.insert(kept, pair)
		end
	end
	local checked = pageLink(if #kept > 0 then base .. "?" .. table.concat(kept, "&") else base, ending("/sites/[^/]+/lists/[^/]+/items"))
	if expand == nil then return checked end
	return checked .. (if string.find(checked, "?", 1, true) then "&" else "?") .. expand
end

-- A JSON object of column values for list item writes.
local function values(value: any, field: string): Options
	assert(type(value) == "table" and next(value) ~= nil, field .. " must be a nonempty object of column values")
	for key in value do assert(type(key) == "string", field .. " must be keyed by internal column name") end
	return value
end

local function count(value: any, field: string, low: number, high: number): number
	assert(type(value) == "number" and value % 1 == 0 and value >= low and value <= high, field .. " must be an integer from " .. low .. " to " .. high)
	return value
end

local function strings(value: any, field: string): {string}
	assert(type(value) == "table" and #value > 0, field .. " must be a nonempty array of strings")
	for key, item in value do
		assert(type(key) == "number" and type(item) == "string" and item ~= "", field .. " must be a nonempty array of strings")
	end
	return value
end

local function each(value: any): {any}
	return if type(value) == "table" then value else {}
end

help.functions.search = {
	description = [[Microsoft Search across every SharePoint site and OneDrive the user can open, files others shared
with them included: {value={{hitsContainers={{hits={{hitId, rank, summary, resource}}, total,
moreResultsAvailable}}}}}. queryString is KQL: words, "exact phrases", AND/OR, filetype:docx,
path:"https://contoso.sharepoint.com/sites/marketing", author:"Ana Silva", LastModifiedTime>2026-01-01.
entityTypes defaults to {'driveItem'}; add 'listItem' for list rows (it matches files too), 'list',
'site' or 'drive'. A driveItem hit's resource carries id and parentReference.driveId for the files
operations. Page with from and size (at most 500; Graph's default is 25). sortProperties cannot sort
drives. Search finds shared files but cannot list everything shared with the user, and a sharing
link cannot be opened directly: search for the file instead.]],
	inputSchema = {
		type = "object",
		properties = {
			queryString = {type = "string", minLength = 1},
			entityTypes = {type = "array", minItems = 1, items = {type = "string", enum = {"driveItem", "listItem", "list", "site", "drive"}}},
			from = {type = "integer", minimum = 0},
			size = {type = "integer", minimum = 1, maximum = 500},
			fields = {type = "array", minItems = 1, items = {type = "string", minLength = 1}, description = "Resource properties to return, such as name or webUrl; list columns need listItem in entityTypes."},
			sortProperties = {type = "array", minItems = 1, maxItems = 5, items = {type = "object", properties = {name = ID, isDescending = {type = "boolean"}}, required = {"name"}, additionalProperties = false}},
		},
		required = {"queryString"},
		additionalProperties = false,
		examples = {{queryString = "quarterly budget filetype:xlsx", size = 10}, {queryString = "path:\"https://contoso.sharepoint.com/sites/marketing\" launch", entityTypes = {"driveItem", "listItem"}, from = 10, size = 10}} :: {any},
	},
	annotations = READ,
}
function exports.search(input: any): Options
	local args = options(input)
	local search: Options = {query = {queryString = text(args.queryString, "queryString")}, entityTypes = {"driveItem"}}
	if args.entityTypes ~= nil then
		search.entityTypes = strings(args.entityTypes, "entityTypes")
		for _, kind in search.entityTypes do
			assert(ENTITY_TYPES[kind], "entityTypes may contain only driveItem, listItem, list, site and drive")
		end
	end
	if args.from ~= nil then search.from = count(args.from, "from", 0, 2147483647) end
	if args.size ~= nil then search.size = count(args.size, "size", 1, 500) end
	if args.fields ~= nil then search.fields = strings(args.fields, "fields") end
	if args.sortProperties ~= nil then
		assert(type(args.sortProperties) == "table" and #args.sortProperties > 0 and #args.sortProperties <= 5, "sortProperties must be an array of 1 to 5 sorts")
		for _, kind in search.entityTypes do assert(kind ~= "drive", "sortProperties cannot sort drives") end
		local sorts: {Options} = {}
		for key, sort in args.sortProperties do
			assert(type(key) == "number" and type(sort) == "table", "sortProperties must be an array of {name, isDescending?}")
			local item = options(sort)
			local entry = {name = text(item.name, "sortProperties.name"), isDescending = item.isDescending}
			assert(entry.isDescending == nil or type(entry.isDescending) == "boolean", "sortProperties.isDescending must be a boolean")
			item.name, item.isDescending = nil, nil
			done("search", item)
			table.insert(sorts, entry)
		end
		search.sortProperties = sorts
	end
	args.queryString, args.entityTypes, args.from, args.size, args.fields, args.sortProperties = nil, nil, nil, nil, nil, nil
	done("search", args)
	-- A search is a read, so its transient server errors stay retryable.
	local result = call("search", "POST", GRAPH .. "/search/query", {requests = {search}}, nil, false)
	for _, response in each(result.value) do
		for _, container in each(if type(response) == "table" then response.hitsContainers else nil) do
			for _, hit in each(if type(container) == "table" then container.hits else nil) do
				local resource = if type(hit) == "table" then hit.resource else nil
				if type(resource) == "table" then
					for _, key in SIGNED do resource[key] = nil end
				end
			end
		end
	end
	return result
end

sites.help.functions.search = {
	description = "One page of sites whose name or description match search: {value={site}, ['@odata.nextLink']?}, each with " .. SITE .. " by default.",
	inputSchema = {
		type = "object",
		properties = {search = {type = "string", minLength = 1}, select = selected(SITE), top = TOP, nextLink = NEXT},
		additionalProperties = false,
		examples = {{search = "marketing", top = 10}},
	},
	annotations = READ,
}
function sites.search(input: any): Options
	local args = options(input)
	assert(args.search ~= nil or args.nextLink ~= nil, "sites.search needs search, or a nextLink")
	return request("sites.search", "GET", "/sites", args, {list = ending("/sites"), query = {"search", "$select", "$top"}, defaults = {select = SITE}})
end

sites.help.functions.get = {
	description = [[One site by siteId, or by webUrl: https://contoso.sharepoint.com/sites/<name>, /teams/<name> and
a OneDrive's https://contoso-my.sharepoint.com/personal/<name> name a site, and any other URL on the
host, such as a page or document, finds the host's root site. A subsite's URL finds its parent site: check
the result's webUrl, and reach subsites with sites.listSubsites.]],
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, webUrl = {type = "string", minLength = 1}, select = selected(SITE)},
		oneOf = {{required = {"siteId"}}, {required = {"webUrl"}}},
		additionalProperties = false,
		examples = {{webUrl = "https://contoso.sharepoint.com/sites/marketing"}, {siteId = "root"}} :: {any},
	},
	annotations = READ,
}
function sites.get(input: any): Options
	local args = options(input)
	local path: string
	if args.webUrl ~= nil then
		assert(args.siteId == nil, "sites.get takes siteId or webUrl, not both")
		path = siteByUrl(text(args.webUrl, "webUrl"))
	else
		path = sitePath(args.siteId)
	end
	args.siteId, args.webUrl = nil, nil
	if args.select == nil then args.select = SITE end
	local href = GRAPH .. path .. query(args, {"$select"})
	done("sites.get", args)
	return call("sites.get", "GET", href)
end

sites.help.functions.listFollowed = {
	description = "One page of the sites the user follows: {value={site}, ['@odata.nextLink']?}. Microsoft notes this list can be incomplete.",
	inputSchema = {type = "object", properties = {select = selected(SITE), nextLink = NEXT}, additionalProperties = false, examples = {{select = "id,displayName,webUrl"}}},
	annotations = READ,
}
function sites.listFollowed(args: Options?): Options
	return request("sites.listFollowed", "GET", "/me/followedSites", args, {list = ending("/me/followedSites"), query = {"$select"}, defaults = {select = SITE}})
end

sites.help.functions.listSubsites = {
	description = "One page of a site's direct subsites: {value={site}, ['@odata.nextLink']?}.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, select = selected(SITE), top = TOP, nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE}},
	},
	annotations = READ,
}
function sites.listSubsites(args: Options?): Options
	return request("sites.listSubsites", "GET", "/sites/{siteId}/sites", args, {list = ending("/sites/[^/]+/sites"), query = {"$select", "$top"}, defaults = {select = SITE}})
end

files.help.functions.listDrives = {
	description = "One page of a site's document libraries: {value={drive}, ['@odata.nextLink']?}, each with " .. DRIVE .. " by default.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, select = selected(DRIVE), nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE}},
	},
	annotations = READ,
}
function files.listDrives(args: Options?): Options
	return request("files.listDrives", "GET", "/sites/{siteId}/drives", args, {list = ending("/sites/[^/]+/drives"), query = {"$select"}, defaults = {select = DRIVE}})
end

files.help.functions.getDrive = {
	description = "One document library by driveId, or a site's default library by siteId: {id, name, driveType, webUrl, owner, quota}.",
	inputSchema = {
		type = "object",
		properties = {driveId = DRIVE_ID, siteId = SITE_ID, select = {type = {"string", "array"}, items = {type = "string"}}},
		oneOf = {{required = {"driveId"}}, {required = {"siteId"}}},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE}, {driveId = DRIVE_EXAMPLE, select = "id,name,quota"}} :: {any},
	},
	annotations = READ,
}
function files.getDrive(input: any): Options
	local args = options(input)
	assert((args.driveId == nil) ~= (args.siteId == nil), "files.getDrive takes driveId or siteId")
	return request("files.getDrive", "GET", if args.driveId ~= nil then "/drives/{driveId}" else "/sites/{siteId}/drive", args, {query = {"$select"}})
end

files.help.functions.get = {
	description = [[One driveItem {id, name, size, file?={mimeType}, folder?={childCount}, parentReference,
lastModifiedDateTime, webUrl}: by itemId, by path relative to the library's root such as
'Proposals/Q3 plan.docx', or the root folder without either. Names containing % or : can only be
reached by itemId.]],
	inputSchema = {
		type = "object",
		properties = {driveId = DRIVE_ID, itemId = ID, path = {type = "string", minLength = 1}, select = selected(ITEM)},
		required = {"driveId"},
		["not"] = {required = {"itemId", "path"}},
		additionalProperties = false,
		examples = {{driveId = DRIVE_EXAMPLE, path = "Proposals/Q3 plan.docx"}, {driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, select = "id,name,size"}} :: {any},
	},
	annotations = READ,
}
function files.get(input: any): Options
	local args = options(input)
	local href = GRAPH .. itemPath(args.driveId, args.itemId, "itemId")
	if args.path ~= nil then
		assert(args.itemId == nil, "files.get takes itemId or path, not both")
		local segments: {string} = {}
		for part in string.gmatch(text(args.path, "path"), "[^/]+") do table.insert(segments, itemName(part, "path")) end
		if #segments > 0 then href ..= ":/" .. table.concat(segments, "/") .. ":" end
	end
	args.driveId, args.itemId, args.path = nil, nil, nil
	if args.select == nil then args.select = ITEM end
	href ..= query(args, {"$select"})
	done("files.get", args)
	return call("files.get", "GET", href)
end

files.help.functions.listChildren = {
	description = "One page of a folder's driveItems, the library's root folder without itemId: {value={driveItem}, ['@odata.nextLink']?}. top is at most 999 (default 200); orderby is e.g. 'name' or 'lastModifiedDateTime desc'.",
	inputSchema = {
		type = "object",
		properties = {driveId = DRIVE_ID, itemId = ID, select = selected(ITEM), top = TOP, orderby = {type = "string"}, nextLink = NEXT},
		additionalProperties = false,
		examples = {{driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, top = 50, orderby = "name"}},
	},
	annotations = READ,
}
function files.listChildren(input: any): Options
	local args = options(input)
	local href = ""
	if args.nextLink == nil then
		href = GRAPH .. itemPath(args.driveId, args.itemId, "itemId") .. "/children"
		args.driveId, args.itemId = nil, nil
	end
	return page("files.listChildren", href, ending("/drives/[^/]+/[^:]+/children"), args, {"$select", "$top", "$orderby"})
end

files.help.functions.search = {
	description = "One page of driveItems in one document library whose name, metadata or content match q: {value={driveItem}, ['@odata.nextLink']?}. q cannot contain / or %. To search every site, use search.",
	inputSchema = {
		type = "object",
		properties = {driveId = DRIVE_ID, q = {type = "string", minLength = 1}, select = selected(ITEM), top = TOP, nextLink = NEXT},
		additionalProperties = false,
		examples = {{driveId = DRIVE_EXAMPLE, q = "quarterly budget", top = 10}},
	},
	annotations = READ,
}
function files.search(input: any): Options
	local args = options(input)
	local href = ""
	if args.nextLink == nil then
		-- OData quotes a literal by doubling its single quotes.
		href = GRAPH .. itemPath(args.driveId, nil, "itemId") .. "/search(q='" .. url.segment((string.gsub(text(args.q, "q"), "'", "''")), "q") .. "')"
		args.driveId, args.q = nil, nil
	end
	return page("files.search", href, ending("/drives/[^/]+/root/[%w%.]*search%(q='[^/]*'%)"), args, {"$select", "$top"})
end

files.help.functions.download = {
	description = "Saves a file's bytes to a session path and returns {path, url, size}, where url is a signed Houston download link. format='pdf' converts Word, Excel, PowerPoint and other documents of up to 2 MB to PDF.",
	inputSchema = {
		type = "object",
		properties = {driveId = DRIVE_ID, itemId = ID, path = {type = "string", minLength = 1, description = "Session file path to write."}, format = {type = "string", enum = {"pdf"}}},
		required = {"driveId", "itemId", "path"},
		additionalProperties = false,
		examples = {{driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, path = "plan.docx"}, {driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, path = "plan.pdf", format = "pdf"}} :: {any},
	},
	annotations = READ,
}
-- Graph answers with a redirect to the file's preauthenticated link, which expires within minutes.
function files.download(input: any): Options
	local args = options(input)
	local href = GRAPH .. itemPath(args.driveId, text(args.itemId, "itemId"), "itemId") .. "/content"
	local path = text(args.path, "path")
	assert(args.format == nil or args.format == "pdf", "format must be 'pdf'")
	args.driveId, args.itemId, args.path = nil, nil, nil
	href ..= query(args, {"format"})
	done("files.download", args)
	return save("files.download", path, function(): HttpResponse
		local response = await(http.request({method = "GET", url = href, headers = identified()}))
		if response.statusCode < 300 or response.statusCode >= 400 then return response end
		local location = response.headers.location
		local link: string = if location and location[1] then location[1] else ""
		response.body:close()
		if not allowedDownload(link) then
			houston.fail({operation = "files.download", layer = "upstream", upstream_status = response.statusCode, retryable = false,
				message = if link == "" then "SharePoint redirected the download without a location" else "SharePoint redirected the download to an unexpected host"})
		end
		local signed = await(http.request({method = "GET", url = link, headers = identified()}))
		local status = signed.statusCode
		if status ~= 200 then
			signed.body:close()
			local fresh = status == 403 or status == 429 or status >= 500
			houston.fail({operation = "files.download", layer = "upstream", upstream_status = status, retryable = fresh,
				message = "The SharePoint download link failed with HTTP " .. tostring(status) .. (if fresh then "; call again for a fresh link" else "")})
		end
		return signed
	end)
end

lists.help.functions.list = {
	description = "One page of a site's lists and libraries: {value={list}, ['@odata.nextLink']?}, each with " .. LIST .. " by default; list.template tells a genericList from a documentLibrary, and list.hidden marks lists hidden from site navigation.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, select = selected(LIST), top = TOP, nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE}},
	},
	annotations = READ,
}
function lists.list(args: Options?): Options
	return request("lists.list", "GET", "/sites/{siteId}/lists", args, {list = ending("/sites/[^/]+/lists"), query = {"$select", "$top"}, defaults = {select = LIST}})
end

lists.help.functions.get = {
	description = "One list, with " .. LIST .. " by default.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, listId = LIST_ID, select = selected(LIST)},
		required = {"siteId", "listId"},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, listId = "Projects"}},
	},
	annotations = READ,
}
function lists.get(args: Options?): Options
	return request("lists.get", "GET", "/sites/{siteId}/lists/{listId}", args, {query = {"$select"}, defaults = {select = LIST}})
end

lists.help.functions.listColumns = {
	description = [[One page of a list's columns: {value={columnDefinition}, ['@odata.nextLink']?}. name is the internal
name that item fields use (Project_x0020_Name for 'Project Name'); displayName is the label people see.
indexed columns filter efficiently; readOnly columns cannot be written; a facet such as text, number,
choice={choices}, dateTime, lookup or personOrGroup gives the type.]],
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, listId = LIST_ID, select = {type = {"string", "array"}, items = {type = "string"}}, nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE}},
	},
	annotations = READ,
}
function lists.listColumns(args: Options?): Options
	return request("lists.listColumns", "GET", "/sites/{siteId}/lists/{listId}/columns", args, {list = ending("/sites/[^/]+/lists/[^/]+/columns"), query = {"$select"}})
end

lists.help.functions.listItems = {
	description = [[One page of a list's items with their column values: {value={{id, fields={...}, webUrl, lastModifiedDateTime,
...}}, ['@odata.nextLink']?}. fields narrows the columns returned. filter is OData on fields, such as
"fields/Status eq 'Done'"; lists over 5,000 items accept a filter or orderby only on an indexed
column (see lists.listColumns). Lookup and person columns return <Name>LookupId unless named in fields;
a query reads at most 12 lookup columns.]],
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, listId = LIST_ID, fields = FIELDS, filter = {type = "string", minLength = 1}, orderby = {type = "string", minLength = 1}, top = TOP, nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE, fields = {"Title", "Status"}, filter = "fields/Status eq 'Done'", top = 50}},
	},
	annotations = READ,
}
function lists.listItems(input: any): Options
	local args = options(input)
	local href: string
	if args.nextLink ~= nil then
		local link = text(args.nextLink, "nextLink")
		args.nextLink = nil
		assert(next(args) == nil, "lists.listItems takes nextLink alone, from a previous page of the same list")
		href = itemsLink(link)
	else
		href = GRAPH .. listPath(args.siteId, args.listId) .. "/items?$expand=" .. expandFields(args.fields)
		args.siteId, args.listId, args.fields = nil, nil, nil
		href ..= more(args, {"$filter", "$orderby", "$top"})
		done("lists.listItems", args)
	end
	local result = call("lists.listItems", "GET", href, nil, UNINDEXED)
	if result.value == nil then result.value = json.decode("[]") end
	return result
end

lists.help.functions.getItem = {
	description = "One list item with its column values: {id, fields={...}, webUrl, ...}. fields narrows the columns returned.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, listId = LIST_ID, itemId = {type = "string", minLength = 1, description = "The item's id, a number as a string such as '4'."}, fields = FIELDS},
		required = {"siteId", "listId", "itemId"},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE, itemId = "4", fields = "Title,Status"}},
	},
	annotations = READ,
}
function lists.getItem(input: any): Options
	local args = options(input)
	local href = GRAPH .. listPath(args.siteId, args.listId)
		.. "/items/" .. url.segment(text(args.itemId, "itemId"), "itemId") .. "?$expand=" .. expandFields(args.fields)
	args.siteId, args.listId, args.itemId, args.fields = nil, nil, nil, nil
	done("lists.getItem", args)
	return call("lists.getItem", "GET", href)
end

pages.help.functions.list = {
	description = "One page of a site's modern pages: {value={sitePage}, ['@odata.nextLink']?}, each with id, name, title, webUrl, pageLayout and publishingState.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, select = {type = {"string", "array"}, items = {type = "string"}}, top = TOP, filter = {type = "string", minLength = 1}, nextLink = NEXT},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, top = 20}},
	},
	annotations = READ,
}
function pages.list(args: Options?): Options
	return request("pages.list", "GET", "/sites/{siteId}/pages", args, {list = ending("/sites/[^/]+/pages"), query = {"$select", "$top", "$filter"}})
end

pages.help.functions.get = {
	description = "One modern page with its content: {id, title, webUrl, canvasLayout={horizontalSections={{columns={{webparts}}}}, verticalSection?}}; text web parts carry innerHtml.",
	inputSchema = {
		type = "object",
		properties = {siteId = SITE_ID, pageId = ID, select = {type = {"string", "array"}, items = {type = "string"}}},
		required = {"siteId", "pageId"},
		additionalProperties = false,
		examples = {{siteId = SITE_EXAMPLE, pageId = "8f1f6a2e-3b4c-4d5e-9f60-7a8b9c0d1e2f"}},
	},
	annotations = READ,
}
function pages.get(input: any): Options
	local args = options(input)
	local href = GRAPH .. sitePath(args.siteId) .. "/pages/" .. url.segment(text(args.pageId, "pageId"), "pageId") .. "/microsoft.graph.sitePage?$expand=canvasLayout"
	args.siteId, args.pageId = nil, nil
	href ..= more(args, {"$select"})
	done("pages.get", args)
	return call("pages.get", "GET", href)
end

if WRITES then
	files.help.functions.createFolder = {
		description = "Creates a folder in parentId, or in the library's root folder, and returns its driveItem. conflictBehavior defaults to 'fail'.",
		inputSchema = {
			type = "object",
			properties = {driveId = DRIVE_ID, name = {type = "string", minLength = 1}, parentId = ID, conflictBehavior = CONFLICT},
			required = {"driveId", "name"},
			additionalProperties = false,
			examples = {{driveId = DRIVE_EXAMPLE, name = "Reports"}, {driveId = DRIVE_EXAMPLE, name = "2026", parentId = ITEM_EXAMPLE, conflictBehavior = "rename"}} :: {any},
		},
		annotations = WRITE,
	}
	function files.createFolder(input: any): Options
		local args = options(input)
		local href = GRAPH .. itemPath(args.driveId, args.parentId, "parentId") .. "/children"
		local body = {name = text(args.name, "name"), folder = {}, ["@microsoft.graph.conflictBehavior"] = conflictBehavior(args.conflictBehavior, "fail")}
		args.driveId, args.parentId, args.name, args.conflictBehavior = nil, nil, nil, nil
		done("files.createFolder", args)
		return call("files.createFolder", "POST", href, body)
	end

	files.help.functions.upload = {
		description = [[Streams a session file into parentId or the library's root folder and returns its driveItem. Files of
up to 250 MB are accepted, but the upload must finish within the call's time limit (about 30 s).
name defaults to the path's basename and cannot contain % or :; by default an existing name gets a
numbered copy. With itemId instead, replaces that file's content. A failed upload may leave nothing
or a complete file: check with files.listChildren before retrying. Libraries that require check-out
refuse changes to files that are not checked out.]],
		inputSchema = {
			type = "object",
			properties = {
				driveId = DRIVE_ID,
				path = {type = "string", minLength = 1, description = "Session file to upload."},
				parentId = ID, name = {type = "string", minLength = 1}, conflictBehavior = CONFLICT,
				itemId = {type = "string", minLength = 1, description = "A file whose content to replace; excludes parentId, name and conflictBehavior."},
				contentType = {type = "string", minLength = 1, description = "Defaults to application/octet-stream."},
			},
			required = {"driveId", "path"},
			additionalProperties = false,
			examples = {{driveId = DRIVE_EXAMPLE, path = "plan.pdf", parentId = ITEM_EXAMPLE, contentType = "application/pdf"}, {driveId = DRIVE_EXAMPLE, path = "plan.pdf", itemId = ITEM_EXAMPLE}} :: {any},
		},
		annotations = WRITE,
	}
	function files.upload(input: any): Options
		local args = options(input)
		local path = text(args.path, "path")
		local contentType = text(args.contentType or "application/octet-stream", "contentType")
		local href: string
		if args.itemId ~= nil then
			assert(args.parentId == nil and args.name == nil and args.conflictBehavior == nil,
				"files.upload with itemId replaces content only; omit parentId, name and conflictBehavior")
			href = GRAPH .. itemPath(args.driveId, text(args.itemId, "itemId"), "itemId") .. "/content"
		else
			href = GRAPH .. itemPath(args.driveId, args.parentId, "parentId") .. ":/" .. itemName(args.name or string.match(path, "[^/]+$"), "name")
				.. ":/content?@microsoft.graph.conflictBehavior=" .. conflictBehavior(args.conflictBehavior, "rename")
		end
		args.driveId, args.path, args.contentType, args.itemId, args.parentId, args.name, args.conflictBehavior = nil, nil, nil, nil, nil, nil, nil
		done("files.upload", args)
		assert(await(fs.stat(path)).size <= MAX_UPLOAD, "files.upload handles files up to 250 MB")
		return decode("files.upload", await(http.request({method = "PUT", url = href,
			headers = identified({["Content-Type"] = {contentType}}), body = fs.open(path, "r")})), true)
	end

	files.help.functions.update = {
		description = "Renames an item, changes its description, or moves it within its library with parentReference={id=<folder itemId>}; returns the driveItem. Items cannot move to another library: copy, then delete.",
		inputSchema = {
			type = "object",
			properties = {driveId = DRIVE_ID, itemId = ID, name = {type = "string", minLength = 1}, description = {type = "string"}, parentReference = REFERENCE, select = selected(ITEM)},
			required = {"driveId", "itemId"},
			additionalProperties = true,
			examples = {{driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, name = "Q3 plan (final).docx"}},
		},
		annotations = WRITE,
	}
	function files.update(args: Options?): Options
		return request("files.update", "PATCH", "/drives/{driveId}/items/{itemId}", args, {body = true, defaults = {select = ITEM}, query = {"$select"}})
	end

	files.help.functions.copy = {
		description = [[Copies an item into parentReference={driveId?, id}, in this library or another one (driveId from
files.listDrives); name is required to copy into the same folder. Returns {success=true}: SharePoint
copies in the background and reports no later failure, such as a name conflict, so list the
destination to find the copy.]],
		inputSchema = {
			type = "object",
			properties = {driveId = DRIVE_ID, itemId = ID, parentReference = REFERENCE, name = {type = "string", minLength = 1}},
			required = {"driveId", "itemId", "parentReference"},
			additionalProperties = false,
			examples = {{driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE, parentReference = {driveId = "b!x-2", id = "01BYE5RZ2BXHFM2TBFTJ7QXAG6KD4V4S7L"}, name = "Q3 plan copy.docx"}},
		},
		annotations = WRITE,
	}
	function files.copy(args: Options?): Options
		return request("files.copy", "POST", "/drives/{driveId}/items/{itemId}/copy", args, {body = true})
	end

	files.help.functions.delete = {
		description = "Moves an item to the site's recycle bin and returns {success=true}.",
		inputSchema = {
			type = "object",
			properties = {driveId = DRIVE_ID, itemId = ID},
			required = {"driveId", "itemId"},
			additionalProperties = false,
			examples = {{driveId = DRIVE_EXAMPLE, itemId = ITEM_EXAMPLE}},
		},
		annotations = DESTRUCTIVE,
	}
	function files.delete(args: Options?): Options
		return request("files.delete", "DELETE", "/drives/{driveId}/items/{itemId}", args)
	end

	lists.help.functions.createItem = {
		description = "Adds an item with fields, column values keyed by internal name (see lists.listColumns), and returns it: {id, fields={...}, ...}.",
		inputSchema = {
			type = "object",
			properties = {siteId = SITE_ID, listId = LIST_ID, fields = VALUES},
			required = {"siteId", "listId", "fields"},
			additionalProperties = false,
			examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE, fields = {Title = "Launch plan", Status = "Planned"}}},
		},
		annotations = WRITE,
	}
	function lists.createItem(input: any): Options
		local args = options(input)
		local href = GRAPH .. listPath(args.siteId, args.listId) .. "/items"
		local body = {fields = values(args.fields, "fields")}
		args.siteId, args.listId, args.fields = nil, nil, nil
		done("lists.createItem", args)
		return call("lists.createItem", "POST", href, body)
	end

	lists.help.functions.updateItem = {
		description = "Changes an item's column values, given as fields keyed by internal name, and returns its updated fields.",
		inputSchema = {
			type = "object",
			properties = {siteId = SITE_ID, listId = LIST_ID, itemId = ID, fields = VALUES},
			required = {"siteId", "listId", "itemId", "fields"},
			additionalProperties = false,
			examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE, itemId = "4", fields = {Status = "Done"}}},
		},
		annotations = WRITE,
	}
	function lists.updateItem(input: any): Options
		local args = options(input)
		local href = GRAPH .. listPath(args.siteId, args.listId)
			.. "/items/" .. url.segment(text(args.itemId, "itemId"), "itemId") .. "/fields"
		local body = values(args.fields, "fields")
		args.siteId, args.listId, args.itemId, args.fields = nil, nil, nil, nil
		done("lists.updateItem", args)
		return call("lists.updateItem", "PATCH", href, body)
	end

	lists.help.functions.deleteItem = {
		description = "Deletes a list item and returns {success=true}.",
		inputSchema = {
			type = "object",
			properties = {siteId = SITE_ID, listId = LIST_ID, itemId = ID},
			required = {"siteId", "listId", "itemId"},
			additionalProperties = false,
			examples = {{siteId = SITE_EXAMPLE, listId = LIST_EXAMPLE, itemId = "4"}},
		},
		annotations = DESTRUCTIVE,
	}
	function lists.deleteItem(args: Options?): Options
		return request("lists.deleteItem", "DELETE", "/sites/{siteId}/lists/{listId}/items/{itemId}", args)
	end
end

return exports
