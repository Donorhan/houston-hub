-- Strava API v3 (https://www.strava.com/api/v3) for the connected athlete.
-- Arguments and results keep Strava's native field names.
type Options = {[string]: any}
type Field = {string}

local API = "https://www.strava.com/api/v3"
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_PAGE = 1000000
local STREAM_KEYS = {"time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth"}
local SEGMENT_STREAM_KEYS = {"distance", "latlng", "altitude"}
local TAGS = {"WithPet", "Recovery", "Competition", "ForACause", "Commute"}
local DATA_TYPES = {"fit", "fit.gz", "tcx", "tcx.gz", "gpx", "gpx.gz", "json"}

-- A copy of an options object, refusing fields the operation does not take.
local function options(input: any, operation: string, allowed: {string}): Options
	if input == nil then return {} end
	assert(type(input) == "table", operation .. " takes one options object")
	for key in input do
		assert(type(key) == "string" and table.find(allowed, key) ~= nil, operation .. " received an unknown option " .. tostring(key))
	end
	return table.clone(input)
end

local function text(value: any, field: string): string
	assert(type(value) == "string" and value ~= "", field .. " must be a nonempty string")
	return value
end

local function integer(value: any, field: string, min: number, max: number): string
	assert(type(value) == "number" and value == math.floor(value) and value >= min and value <= max,
		field .. " must be an integer from " .. tostring(min) .. " to " .. string.format("%.0f", max))
	return string.format("%.0f", value)
end

local function boolean(value: any, field: string): boolean
	assert(type(value) == "boolean", field .. " must be a boolean")
	return value
end

-- A Strava numeric ID: an integer, or a string of digits for IDs beyond 2^53 - 1, which results
-- carry as strings.
local function id(value: any, field: string): string
	local problem = field .. " must be a positive integer, or a string of digits"
	if type(value) == "number" then
		assert(value == math.floor(value) and value >= 1 and value <= MAX_SAFE_INTEGER, problem)
		return string.format("%.0f", value)
	end
	assert(type(value) == "string" and string.match(value, "^[1-9]%d*$") ~= nil and #value <= 19, problem)
	return value
end

-- Gear IDs are strings such as "b12345678" (bikes) or "g12345678" (shoes).
local function gearId(value: any, field: string): string
	assert(type(value) == "string" and string.match(value, "^%w+$") ~= nil, field .. " must be a gear ID such as b12345678")
	return value
end

local function keys(value: any, allowed: {string}): string
	assert(type(value) == "table" and #value >= 1 and #value <= #allowed, "keys must be an array of 1 to " .. tostring(#allowed) .. " stream types")
	local count = 0
	for _ in value do count += 1 end
	assert(count == #value, "keys must be an array")
	for index, key in value do
		assert(type(key) == "string" and table.find(allowed, key) ~= nil, "keys[" .. tostring(index) .. "] must be one of " .. table.concat(allowed, ", "))
	end
	return table.concat(value, ",")
end

local function tags(value: any): Options
	assert(type(value) == "table", "tags must be an object of tag names and booleans")
	local count = 0
	for name, flag in value do
		assert(type(name) == "string" and table.find(TAGS, name) ~= nil, "tags keys must be among " .. table.concat(TAGS, ", "))
		boolean(flag, "tags." .. name)
		count += 1
	end
	assert(count > 0, "tags must name at least one tag")
	return value
end

-- Form fields for a tags object, sorted so requests are deterministic: tags[WithPet]=true.
local function tagFields(fields: {Field}, value: Options)
	local names: {string} = {}
	for name in value do table.insert(names, name) end
	table.sort(names)
	for _, name in names do table.insert(fields, {"tags[" .. name .. "]", tostring(value[name])}) end
end

local function page(args: Options, query: {string})
	if args.page ~= nil then table.insert(query, "page=" .. integer(args.page, "page", 1, MAX_PAGE)) end
	if args.per_page ~= nil then table.insert(query, "per_page=" .. integer(args.per_page, "per_page", 1, 200)) end
end

local function form(fields: {Field}): string
	local parts: {string} = {}
	for _, field in fields do table.insert(parts, url.encode(field[1]) .. "=" .. url.encode(field[2])) end
	return table.concat(parts, "&")
end

local BACKSLASH = string.byte("\\")
local LONG_DIGITS = "%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+"

-- Luau numbers keep 53 bits, so integers beyond 2^53 - 1 (segment effort, comment and route IDs)
-- would lose digits: decode them as strings of digits instead. Only runs of 16 or more digits are
-- candidates, quoted when they lie outside every JSON string and form a whole integer token. The
-- string state advances once over quotes and escapes, so the scan is linear and keeps only the
-- positions to quote.
local function decode(raw: string): any
	if not string.find(raw, LONG_DIGITS) then return json.decode(raw) end
	local splices: {number} = {}
	local cursor, inString = 1, false
	local special = string.find(raw, '[\\"]')
	local at = 1
	while true do
		local start, finish = string.find(raw, LONG_DIGITS, at)
		if not start or not finish then break end
		while special and special < start do
			local position: number = special
			if string.byte(raw, position) == BACKSLASH then
				cursor = position + 2
			else
				inString = not inString
				cursor = position + 1
			end
			special = string.find(raw, '[\\"]', cursor)
		end
		if not inString then
			local first = if string.sub(raw, start - 1, start - 1) == "-" then start - 1 else start
			local whole = not string.find(string.sub(raw, first - 1, first - 1), "[%d%.eE+%-]")
				and not string.find(string.sub(raw, finish + 1, finish + 1), "[%.eE]")
			local digits = finish - start + 1
			if whole and (digits > 16 or (digits == 16 and string.sub(raw, start, finish) > "9007199254740991")) then
				table.insert(splices, first)
				table.insert(splices, finish)
			end
		end
		at = finish + 1
	end
	if #splices == 0 then return json.decode(raw) end
	local parts: {string} = {}
	local last = 1
	for index = 1, #splices, 2 do
		table.insert(parts, string.sub(raw, last, splices[index] - 1))
		table.insert(parts, '"' .. string.sub(raw, splices[index], splices[index + 1]) .. '"')
		last = splices[index + 1] + 1
	end
	table.insert(parts, string.sub(raw, last))
	return json.decode(table.concat(parts))
end

-- X-RateLimit-* and X-ReadRateLimit-* hold "<15-minute>,<daily>" limits and usage.
local function usage(headers: HttpHeaders, name: string, label: string): (string?, boolean)
	local limit, used = headers["x-" .. name .. "-limit"], headers["x-" .. name .. "-usage"]
	if not limit or not used then return nil, false end
	local quarter, daily = string.match(limit[1] or "", "^(%d+),(%d+)$")
	local usedQuarter, usedDaily = string.match(used[1] or "", "^(%d+),(%d+)$")
	if not quarter or not daily or not usedQuarter or not usedDaily then return nil, false end
	return label .. " " .. usedQuarter .. "/" .. quarter .. " in 15 minutes, " .. usedDaily .. "/" .. daily .. " today",
		tonumber(usedDaily) :: number >= tonumber(daily) :: number
end

-- Strava errors are {message, errors = {{resource, field, code}}}. A permission the athlete
-- unticked on Strava's consent page reads as field "activity:read_permission", code "missing".
-- Server errors are retryable only for idempotent calls: a create may already have been applied.
-- Upload errors may come as HTML, whose text is kept; a body beyond 4 KiB gives the status alone.
local function fail(operation: string, response: HttpResponse, idempotent: boolean): never
	local status = response.statusCode
	local raw = await(response.body:readPrefix(4096))
	local ok, problem = pcall(json.decode, raw)
	local message = "Strava HTTP " .. tostring(status)
	local missing: string? = nil
	if ok and type(problem) == "table" then
		if type(problem.message) == "string" then message ..= ": " .. string.sub(problem.message, 1, 300) end
		local errors = if type(problem.errors) == "table" then problem.errors else {}
		local details: {string} = {}
		for index = 1, math.min(#errors, 5) do
			local item = errors[index]
			if type(item) ~= "table" then continue end
			local words: {string} = {}
			for _, key in {"resource", "field", "code"} do
				if type(item[key]) == "string" and item[key] ~= "" then table.insert(words, string.sub(item[key], 1, 100)) end
			end
			if #words > 0 then table.insert(details, table.concat(words, " ")) end
			if item.code == "missing" and type(item.field) == "string" and string.match(item.field, "_permission$") then
				missing = string.sub(item.field, 1, 100)
			end
		end
		if #details > 0 then message ..= " (" .. table.concat(details, "; ") .. ")" end
	elseif status == 400 and string.match(raw, "^%s*<") then
		message ..= ": " .. string.sub(string.gsub(raw, "<[^>]*>", " "), 1, 300)
	end
	if missing then
		message ..= "; the athlete did not grant " .. missing .. ": reconnect Strava and keep every permission ticked"
	elseif status == 401 then
		message ..= "; reconnect Strava if the athlete revoked Houston's access"
	end
	local daily = false
	if status == 429 then
		local overall, overallDaily = usage(response.headers, "ratelimit", "requests")
		local reads, readsDaily = usage(response.headers, "readratelimit", "non-upload requests")
		if overall then message ..= "; " .. overall end
		if reads then message ..= "; " .. reads end
		daily = overallDaily or readsDaily
		message ..= if daily then "; the daily limit resets at midnight UTC" else "; the 15-minute limit resets on the quarter hour"
	end
	return houston.fail({operation = operation, layer = "upstream", upstream_status = status, message = message,
		retryable = (status == 429 and not daily) or (idempotent and status >= 500)})
end

type Call = {method: string, path: string, query: {string}?, form: {Field}?, json: Options?,
	multipart: {any}?, expect: string, idempotent: boolean}

-- One request to Strava, returning its JSON object or array: expect is "object", "array" or "either".
local function call(operation: string, request: Call): any
	local headers: HttpHeaders = {}
	local body: any = nil
	if request.form then
		headers["Content-Type"] = {"application/x-www-form-urlencoded"}
		body = form(request.form)
	elseif request.json then
		headers["Content-Type"] = {"application/json"}
		body = json.encode(request.json)
	elseif request.multipart then
		local parts = multipart.create(request.multipart)
		headers["Content-Type"] = {parts.contentType}
		body = parts.body
	end
	local query = if request.query and #request.query > 0 then "?" .. table.concat(request.query, "&") else ""
	local response = await(http.request({method = request.method, url = API .. request.path .. query, headers = headers, body = body}))
	if response.statusCode < 200 or response.statusCode >= 300 then fail(operation, response, request.idempotent) end
	local read, raw = pcall(function(): string return await(response.body:readAll()) end)
	if not read then
		if not string.find(tostring(raw), "limit_exceeded", 1, true) then error(raw, 0) end
		houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode, retryable = false,
			message = "Strava's response is over 8 MiB: request fewer stream keys, a smaller per_page or a shorter period"})
	end
	local opening = if request.expect == "array" then "^%s*%[" elseif request.expect == "object" then "^%s*{" else "^%s*[{%[]"
	local ok, value = pcall(decode, raw)
	if not ok or type(value) ~= "table" or not string.match(raw, opening) then
		houston.fail({operation = operation, layer = "upstream", upstream_status = response.statusCode, retryable = false,
			message = "Strava returned an unexpected response instead of JSON " .. (if request.expect == "either" then "data" else request.expect)})
	end
	return value
end

local function get(operation: string, path: string, query: {string}?, expect: string?): any
	return call(operation, {method = "GET", path = path, query = query, expect = expect or "object", idempotent = true})
end

-- Streams a route export (GPX or TCX) to a session file, replacing it only when complete. The file
-- opens first, so an invalid path fails before any request.
local function export(operation: string, args: Options, format: string): Options
	local path = "/routes/" .. id(args.id, "id") .. "/export_" .. format
	local target = text(args.path, "path")
	local output = fs.open(target, "w")
	local ok, err = pcall(function()
		local response = await(http.request({method = "GET", url = API .. path}))
		if response.statusCode ~= 200 then fail(operation, response, true) end
		output:write(response.body)
		await(output:close())
	end)
	if not ok then
		output:cancel()
		pcall(function() await(output:close()) end)
		error(err, 0)
	end
	return {path = target, size = await(fs.stat(target)).size}
end

local help = {
	text = [[Strava API v3 for the connected athlete: their profile, zones and totals; activities with their laps,
zones, comments, kudos and streams (time series such as heart rate, power or GPS points); clubs,
gear, routes (with GPX/TCX export), segments and segment efforts. Every operation takes one options
object with Strava's parameter names and returns Strava's JSON unchanged. Connector calls return
completed values: use them directly, without await.

IDs are integers. Integers beyond 9007199254740991 (some segment effort, comment and route IDs)
come back as strings of digits so that no digit is lost; pass any ID back exactly as received.
Routes and uploads also carry id_str. Gear IDs are strings such as "b12345678". The athlete's own
ID is getLoggedInAthlete().id. Distances are meters, durations seconds, speeds meters per second;
start_date is UTC and start_date_local the athlete's local time (also written with a Z).

Lists return one page as an array: page starts at 1 and per_page is 1 to 200 (Strava's default is
30). Strava may return short pages before the end, so stop at an empty page. Example: the athlete's
activities since 1 January 2026 (epoch seconds):
local page = strava.getLoggedInAthleteActivities({after = 1767225600, per_page = 200, page = 1})

Rate limits belong to Houston's Strava app and are shared by every athlete who connects it: an
overall limit and a lower one for every call except createActivity and createUpload, each per 15
minutes (reset on the quarter hour) and per day (reset at midnight UTC). Prefer per_page = 200 and
summary lists over loops of single reads, and fetch only the streams needed. A 429 error reports
the current usage and limits.

Errors read 'Strava HTTP <status>: <message> (<resource> <field> <code>)'. 404 means the record
does not exist or is not visible to the athlete. A missing permission (field
activity:read_permission, code missing) means the athlete unticked it when connecting: they must
reconnect Strava with every permission ticked. Segment efforts need a Strava subscription, and
activity zones a subscription feature; Strava refuses them otherwise.]] .. (if config.access == "read-write" then [[


Writes: createActivity adds a manual activity, createUpload imports a FIT, TCX, GPX or JSON file
(poll getUploadById until activity_id or error is set), updateActivityById edits an activity,
updateLoggedInAthlete sets the athlete's weight and starSegment stars or unstars a segment. A
failed or interrupted createActivity or createUpload may still have created the activity: list
recent activities before retrying.]] else ""),
	functions = {} :: {[string]: any},
}
local exports: {[string]: any} = {help = help}

-- Schemas and hints shared by several operations.
local ID = {oneOf = {
	{type = "integer", minimum = 1, maximum = MAX_SAFE_INTEGER},
	{type = "string", pattern = "^[1-9][0-9]{0,18}$", description = "IDs beyond 2^53 - 1, as results return them."},
} :: {any}}
local PAGE = {type = "integer", minimum = 1, maximum = MAX_PAGE, description = "Page number, from 1."}
local PER_PAGE = {type = "integer", minimum = 1, maximum = 200, description = "Items per page; Strava's default is 30."}
local SESSION_PATH = {type = "string", minLength = 1, description = "Session file path to write; it is replaced only when the download completes."}
local TAG_OBJECT = {type = "object", minProperties = 1, additionalProperties = false,
	properties = {WithPet = {type = "boolean"}, Recovery = {type = "boolean"}, Competition = {type = "boolean"},
		ForACause = {type = "boolean"}, Commute = {type = "boolean"}},
	description = "Tags to set (true) or clear (false); tags left out stay unchanged. Not with commute."}
local SPORT_TYPE = {type = "string", pattern = "^[A-Za-z]+$",
	description = "Strava sport type, such as Run, TrailRun, Walk, Hike, Ride, GravelRide, MountainBikeRide, VirtualRide, Swim, Rowing, WeightTraining, Workout or Yoga."}
local function keysSchema(allowed: {string}): Options
	return {type = "array", minItems = 1, maxItems = #allowed, uniqueItems = true, items = {type = "string", enum = allowed}}
end
local READ = {readOnlyHint = true, openWorldHint = true}

help.functions.getLoggedInAthlete = {
	description = [[The connected athlete's detailed profile: {id, username, firstname, lastname, city, country, sex,
premium, created_at, weight, ftp, measurement_preference, clubs, bikes, shoes, ...}.]],
	inputSchema = {type = "object", additionalProperties = false, examples = {{}}},
	annotations = READ,
}
function exports.getLoggedInAthlete(input: any): Options
	options(input, "getLoggedInAthlete", {})
	return get("getLoggedInAthlete", "/athlete")
end

help.functions.getLoggedInAthleteZones = {
	description = [[The athlete's heart rate and power zones: {heart_rate = {custom_zones, zones = {{min, max}}},
power = {zones}}.]],
	inputSchema = {type = "object", additionalProperties = false, examples = {{}}},
	annotations = READ,
}
function exports.getLoggedInAthleteZones(input: any): Options
	options(input, "getLoggedInAthleteZones", {})
	return get("getLoggedInAthleteZones", "/athlete/zones")
end

help.functions.getStats = {
	description = [[Activity totals of the connected athlete, whose ID is getLoggedInAthlete().id: recent (last 4
weeks), year-to-date and all-time ride, run and swim totals {count, distance, moving_time,
elapsed_time, elevation_gain}, plus biggest_ride_distance and biggest_climb_elevation_gain.
Totals count only activities visible to Everyone.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = 134815}}},
	annotations = READ,
}
function exports.getStats(input: any): Options
	local args = options(input, "getStats", {"id"})
	return get("getStats", "/athletes/" .. id(args.id, "id") .. "/stats")
end

help.functions.getLoggedInAthleteActivities = {
	description = [[One page of the athlete's activities, as summary activities {id, name, sport_type,
start_date, start_date_local, timezone, distance, moving_time, elapsed_time, total_elevation_gain,
average_speed, average_heartrate?, average_watts?, kudos_count, map = {summary_polyline}, gear_id,
private, visibility, ...}. before and after are epoch seconds limiting start times.]],
	inputSchema = {
		type = "object",
		properties = {before = {type = "integer", minimum = 0, description = "Only activities that started before this epoch time."},
			after = {type = "integer", minimum = 0, description = "Only activities that started after this epoch time."},
			page = PAGE, per_page = PER_PAGE},
		additionalProperties = false,
		examples = {{after = 1767225600, per_page = 200, page = 1}, {}} :: {any},
	},
	annotations = READ,
}
function exports.getLoggedInAthleteActivities(input: any): {Options}
	local args = options(input, "getLoggedInAthleteActivities", {"before", "after", "page", "per_page"})
	local query: {string} = {}
	if args.before ~= nil then table.insert(query, "before=" .. integer(args.before, "before", 0, MAX_SAFE_INTEGER)) end
	if args.after ~= nil then table.insert(query, "after=" .. integer(args.after, "after", 0, MAX_SAFE_INTEGER)) end
	page(args, query)
	return get("getLoggedInAthleteActivities", "/athlete/activities", query, "array")
end

help.functions.getActivityById = {
	description = [[One of the athlete's activities in detail: the summary fields plus description, calories, device_name,
gear, laps, splits_metric, splits_standard, best_efforts, segment_efforts, photos and map.polyline.
include_all_efforts = true also returns hidden segment efforts.]],
	inputSchema = {type = "object", properties = {id = ID, include_all_efforts = {type = "boolean"}},
		required = {"id"}, additionalProperties = false, examples = {{id = 16532880011}, {id = 16532880011, include_all_efforts = true}} :: {any}},
	annotations = READ,
}
function exports.getActivityById(input: any): Options
	local args = options(input, "getActivityById", {"id", "include_all_efforts"})
	local query: {string} = {}
	if args.include_all_efforts ~= nil then
		table.insert(query, "include_all_efforts=" .. tostring(boolean(args.include_all_efforts, "include_all_efforts")))
	end
	return get("getActivityById", "/activities/" .. id(args.id, "id"), query)
end

help.functions.getLapsByActivityId = {
	description = [[An activity's laps, as an array of {id, lap_index, name, start_date, elapsed_time, moving_time,
distance, average_speed, max_speed, average_heartrate?, average_watts?, start_index, end_index, ...}.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = 16532880011}}},
	annotations = READ,
}
function exports.getLapsByActivityId(input: any): {Options}
	local args = options(input, "getLapsByActivityId", {"id"})
	return get("getLapsByActivityId", "/activities/" .. id(args.id, "id") .. "/laps", nil, "array")
end

help.functions.getZonesByActivityId = {
	description = [[An activity's time in heart rate and power zones, as an array of {type = "heartrate" | "power",
distribution_buckets = {{min, max, time}}, score?, sensor_based, ...}. A Strava subscription feature.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = 16532880011}}},
	annotations = READ,
}
function exports.getZonesByActivityId(input: any): {Options}
	local args = options(input, "getZonesByActivityId", {"id"})
	return get("getZonesByActivityId", "/activities/" .. id(args.id, "id") .. "/zones", nil, "array")
end

help.functions.getCommentsByActivityId = {
	description = [[One page of an activity's comments: an array of {id, activity_id, text, created_at,
athlete = {firstname, lastname}, cursor}. For the next page, pass the last comment's cursor as
after_cursor; an empty array ends the list.]],
	inputSchema = {
		type = "object",
		properties = {id = ID, page_size = {type = "integer", minimum = 1, maximum = 200, description = "Comments per page; Strava's default is 30."},
			after_cursor = {type = "string", minLength = 1, description = "cursor of the last comment of the previous page."}},
		required = {"id"},
		additionalProperties = false,
		examples = {{id = 16532880011, page_size = 50}, {id = 16532880011, after_cursor = "abc123%20"}} :: {any},
	},
	annotations = READ,
}
function exports.getCommentsByActivityId(input: any): {Options}
	local args = options(input, "getCommentsByActivityId", {"id", "page_size", "after_cursor"})
	local query: {string} = {}
	if args.page_size ~= nil then table.insert(query, "page_size=" .. integer(args.page_size, "page_size", 1, 200)) end
	if args.after_cursor ~= nil then table.insert(query, "after_cursor=" .. url.encode(text(args.after_cursor, "after_cursor"))) end
	return get("getCommentsByActivityId", "/activities/" .. id(args.id, "id") .. "/comments", query, "array")
end

help.functions.getKudoersByActivityId = {
	description = "One page of the athletes who gave an activity kudos: an array of {firstname, lastname}.",
	inputSchema = {type = "object", properties = {id = ID, page = PAGE, per_page = PER_PAGE}, required = {"id"},
		additionalProperties = false, examples = {{id = 16532880011, per_page = 200}}},
	annotations = READ,
}
function exports.getKudoersByActivityId(input: any): {Options}
	local args = options(input, "getKudoersByActivityId", {"id", "page", "per_page"})
	local query: {string} = {}
	page(args, query)
	return get("getKudoersByActivityId", "/activities/" .. id(args.id, "id") .. "/kudos", query, "array")
end

help.functions.getActivityStreams = {
	description = [[An activity's recorded time series, keyed by type: {time = {data, series_type, original_size,
resolution}, heartrate = {...}, ...}. data holds one value per sample: seconds from the start
(time), meters (distance, altitude), {lat, lng} pairs (latlng), m/s (velocity_smooth), bpm
(heartrate), rpm (cadence), watts, °C (temp), booleans (moving) or percent (grade_smooth). Streams
the device did not record are left out. A long activity's streams are large: request only the keys
needed.]],
	inputSchema = {type = "object", properties = {id = ID, keys = keysSchema(STREAM_KEYS)}, required = {"id", "keys"},
		additionalProperties = false, examples = {{id = 16532880011, keys = {"time", "heartrate", "watts"}}}},
	annotations = READ,
}
function exports.getActivityStreams(input: any): any
	local args = options(input, "getActivityStreams", {"id", "keys"})
	local path = "/activities/" .. id(args.id, "id") .. "/streams"
	return get("getActivityStreams", path, {"keys=" .. url.encode(keys(args.keys, STREAM_KEYS)), "key_by_type=true"}, "either")
end

help.functions.getLoggedInAthleteClubs = {
	description = [[One page of the clubs the athlete belongs to: an array of {id, name, sport_type, city, country,
member_count, private, url, ...}.]],
	inputSchema = {type = "object", properties = {page = PAGE, per_page = PER_PAGE}, additionalProperties = false,
		examples = {{per_page = 200}}},
	annotations = READ,
}
function exports.getLoggedInAthleteClubs(input: any): {Options}
	local args = options(input, "getLoggedInAthleteClubs", {"page", "per_page"})
	local query: {string} = {}
	page(args, query)
	return get("getLoggedInAthleteClubs", "/athlete/clubs", query, "array")
end

help.functions.getClubById = {
	description = [[One club: {id, name, description, sport_type, city, country, member_count, membership, admin,
owner, following_count, url, ...}. Strava no longer lists club members or club activities.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = 231407}}},
	annotations = READ,
}
function exports.getClubById(input: any): Options
	local args = options(input, "getClubById", {"id"})
	return get("getClubById", "/clubs/" .. id(args.id, "id"))
end

help.functions.getGearById = {
	description = [[One of the athlete's bikes or shoes: {id, name, brand_name, model_name, distance (meters), primary,
retired, ...}. getLoggedInAthlete lists the athlete's bikes and shoes with their IDs.]],
	inputSchema = {type = "object", properties = {id = {type = "string", pattern = "^[A-Za-z0-9]+$"}}, required = {"id"},
		additionalProperties = false, examples = {{id = "b12345678"}}},
	annotations = READ,
}
function exports.getGearById(input: any): Options
	local args = options(input, "getGearById", {"id"})
	return get("getGearById", "/gear/" .. gearId(args.id, "id"))
end

help.functions.getRoutesByAthleteId = {
	description = [[One page of the connected athlete's routes (id is getLoggedInAthlete().id): an array of {id, id_str,
name, description, type (1 Ride, 2 Run, 3 Walk, 4 Hike, 5 Trail Run, 6 Gravel Ride, 7 Mountain
Bike Ride), sub_type (1 Road, 2 MTB, 3 Gravel, 4 Trail, 5 Mixed), distance, elevation_gain, estimated_moving_time,
private, starred, map = {summary_polyline}, created_at, ...}.]],
	inputSchema = {type = "object", properties = {id = ID, page = PAGE, per_page = PER_PAGE}, required = {"id"},
		additionalProperties = false, examples = {{id = 134815, per_page = 200}}},
	annotations = READ,
}
function exports.getRoutesByAthleteId(input: any): {Options}
	local args = options(input, "getRoutesByAthleteId", {"id", "page", "per_page"})
	local query: {string} = {}
	page(args, query)
	return get("getRoutesByAthleteId", "/athletes/" .. id(args.id, "id") .. "/routes", query, "array")
end

help.functions.getRouteById = {
	description = "One route in detail: the summary fields plus segments, waypoints and map.polyline.",
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = "3344425285447071234"}}},
	annotations = READ,
}
function exports.getRouteById(input: any): Options
	local args = options(input, "getRouteById", {"id"})
	return get("getRouteById", "/routes/" .. id(args.id, "id"))
end

help.functions.getRouteStreams = {
	description = [[A route's distance, latlng and altitude streams: {type, data, series_type, original_size,
resolution} for each, as an array or keyed by type, as Strava returns them.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = "3344425285447071234"}}},
	annotations = READ,
}
function exports.getRouteStreams(input: any): any
	local args = options(input, "getRouteStreams", {"id"})
	return get("getRouteStreams", "/routes/" .. id(args.id, "id") .. "/streams", nil, "either")
end

help.functions.getRouteAsGPX = {
	description = [[Downloads a route as a GPX file to the session file at path and returns {path, size}. The file can
then be read, attached or uploaded elsewhere.]],
	inputSchema = {type = "object", properties = {id = ID, path = SESSION_PATH}, required = {"id", "path"},
		additionalProperties = false, examples = {{id = "3344425285447071234", path = "routes/morning-loop.gpx"}}},
	annotations = READ,
}
function exports.getRouteAsGPX(input: any): Options
	return export("getRouteAsGPX", options(input, "getRouteAsGPX", {"id", "path"}), "gpx")
end

help.functions.getRouteAsTCX = {
	description = "Downloads a route as a TCX file to the session file at path and returns {path, size}.",
	inputSchema = {type = "object", properties = {id = ID, path = SESSION_PATH}, required = {"id", "path"},
		additionalProperties = false, examples = {{id = "3344425285447071234", path = "routes/morning-loop.tcx"}}},
	annotations = READ,
}
function exports.getRouteAsTCX(input: any): Options
	return export("getRouteAsTCX", options(input, "getRouteAsTCX", {"id", "path"}), "tcx")
end

help.functions.getSegmentById = {
	description = [[One segment: {id, name, activity_type, distance, average_grade, maximum_grade, elevation_high,
elevation_low, climb_category, city, country, private, starred, effort_count, athlete_count,
athlete_segment_stats, xoms, map = {polyline}, ...}.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = 229781}}},
	annotations = READ,
}
function exports.getSegmentById(input: any): Options
	local args = options(input, "getSegmentById", {"id"})
	return get("getSegmentById", "/segments/" .. id(args.id, "id"))
end

help.functions.getLoggedInAthleteStarredSegments = {
	description = "One page of the segments the athlete starred, as summary segments.",
	inputSchema = {type = "object", properties = {page = PAGE, per_page = PER_PAGE}, additionalProperties = false,
		examples = {{per_page = 200}}},
	annotations = READ,
}
function exports.getLoggedInAthleteStarredSegments(input: any): {Options}
	local args = options(input, "getLoggedInAthleteStarredSegments", {"page", "per_page"})
	local query: {string} = {}
	page(args, query)
	return get("getLoggedInAthleteStarredSegments", "/segments/starred", query, "array")
end

help.functions.getSegmentStreams = {
	description = "A segment's requested streams (distance, latlng, altitude), keyed by type like getActivityStreams.",
	inputSchema = {type = "object", properties = {id = ID, keys = keysSchema(SEGMENT_STREAM_KEYS)}, required = {"id", "keys"},
		additionalProperties = false, examples = {{id = 229781, keys = {"latlng", "altitude"}}}},
	annotations = READ,
}
function exports.getSegmentStreams(input: any): any
	local args = options(input, "getSegmentStreams", {"id", "keys"})
	local path = "/segments/" .. id(args.id, "id") .. "/streams"
	return get("getSegmentStreams", path, {"keys=" .. url.encode(keys(args.keys, SEGMENT_STREAM_KEYS)), "key_by_type=true"}, "either")
end

help.functions.getEffortsBySegmentId = {
	description = [[The athlete's efforts on one segment, as an array of {id, activity = {id}, elapsed_time, moving_time,
start_date, start_date_local, distance, pr_rank, average_heartrate?, average_watts?, ...}.
start_date_local and end_date_local (ISO 8601) bound the efforts' start. There is no page option: for
more than per_page efforts, query shorter date ranges. Needs a Strava subscription.]],
	inputSchema = {
		type = "object",
		properties = {segment_id = ID, start_date_local = {type = "string", minLength = 1, description = "ISO 8601, such as 2026-01-01T00:00:00Z."},
			end_date_local = {type = "string", minLength = 1, description = "ISO 8601."}, per_page = PER_PAGE},
		required = {"segment_id"},
		additionalProperties = false,
		examples = {{segment_id = 229781, start_date_local = "2026-01-01T00:00:00Z", end_date_local = "2026-12-31T23:59:59Z", per_page = 200}},
	},
	annotations = READ,
}
function exports.getEffortsBySegmentId(input: any): {Options}
	local args = options(input, "getEffortsBySegmentId", {"segment_id", "start_date_local", "end_date_local", "per_page"})
	local query = {"segment_id=" .. id(args.segment_id, "segment_id")}
	for _, field in {"start_date_local", "end_date_local"} do
		if args[field] ~= nil then table.insert(query, field .. "=" .. url.encode(text(args[field], field))) end
	end
	page(args, query)
	return get("getEffortsBySegmentId", "/segment_efforts", query, "array")
end

help.functions.getSegmentEffortById = {
	description = [[One segment effort: {id, activity, segment, elapsed_time, moving_time, start_date, distance,
start_index, end_index, pr_rank, kom_rank, average_heartrate?, average_watts?, ...}. Effort IDs are
often beyond 2^53 and so strings of digits. Needs a Strava subscription.]],
	inputSchema = {type = "object", properties = {id = ID}, required = {"id"}, additionalProperties = false,
		examples = {{id = "2922283800928553202"}}},
	annotations = READ,
}
function exports.getSegmentEffortById(input: any): Options
	local args = options(input, "getSegmentEffortById", {"id"})
	return get("getSegmentEffortById", "/segment_efforts/" .. id(args.id, "id"))
end

help.functions.getSegmentEffortStreams = {
	description = [[A segment effort's requested time series, keyed by type, with the same keys and values as
getActivityStreams.]],
	inputSchema = {type = "object", properties = {id = ID, keys = keysSchema(STREAM_KEYS)}, required = {"id", "keys"},
		additionalProperties = false, examples = {{id = "2922283800928553202", keys = {"time", "watts"}}}},
	annotations = READ,
}
function exports.getSegmentEffortStreams(input: any): any
	local args = options(input, "getSegmentEffortStreams", {"id", "keys"})
	local path = "/segment_efforts/" .. id(args.id, "id") .. "/streams"
	return get("getSegmentEffortStreams", path, {"keys=" .. url.encode(keys(args.keys, STREAM_KEYS)), "key_by_type=true"}, "either")
end

if config.access == "read-write" then
	local WRITE = {readOnlyHint = false, destructiveHint = false, openWorldHint = true}
	local IDEMPOTENT = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = true}

	help.functions.updateLoggedInAthlete = {
		description = "Sets the athlete's weight in kilograms and returns the updated detailed athlete.",
		inputSchema = {type = "object", properties = {weight = {type = "number", exclusiveMinimum = 0, maximum = 500}},
			required = {"weight"}, additionalProperties = false, examples = {{weight = 71.5}}},
		annotations = IDEMPOTENT,
	}
	function exports.updateLoggedInAthlete(input: any): Options
		local args = options(input, "updateLoggedInAthlete", {"weight"})
		local weight = args.weight
		assert(type(weight) == "number" and weight > 0 and weight <= 500, "weight must be a number of kilograms above 0, at most 500")
		return call("updateLoggedInAthlete", {method = "PUT", path = "/athlete", form = {{"weight", tostring(weight)}},
			expect = "object", idempotent = true})
	end

	help.functions.createActivity = {
		description = [[Adds a manual activity (without GPS data) and returns the detailed activity. start_date_local is the
athlete's local start time in ISO 8601; elapsed_time is seconds and distance meters. trainer and
commute mark indoor and commute activities; tags (WithPet, Recovery, Competition, ForACause,
Commute) cannot be combined with commute. To import a recorded file, use createUpload instead.]],
		inputSchema = {
			type = "object",
			properties = {name = {type = "string", minLength = 1}, sport_type = SPORT_TYPE,
				start_date_local = {type = "string", minLength = 1, description = "ISO 8601, such as 2026-11-16T07:30:00Z."},
				elapsed_time = {type = "integer", minimum = 1}, description = {type = "string"},
				distance = {type = "number", minimum = 0}, trainer = {type = "boolean"}, commute = {type = "boolean"}, tags = TAG_OBJECT},
			required = {"name", "sport_type", "start_date_local", "elapsed_time"},
			additionalProperties = false,
			examples = {
				{name = "Lunch run", sport_type = "Run", start_date_local = "2026-11-16T12:15:00Z", elapsed_time = 2700, distance = 8000},
				{name = "Gym session", sport_type = "WeightTraining", start_date_local = "2026-11-16T18:00:00Z", elapsed_time = 3600,
					description = "Legs day", trainer = true, tags = {Recovery = true}},
			} :: {any},
		},
		annotations = WRITE,
	}
	function exports.createActivity(input: any): Options
		local args = options(input, "createActivity", {"name", "sport_type", "start_date_local", "elapsed_time", "description", "distance", "trainer", "commute", "tags"})
		local fields: {Field} = {
			{"name", text(args.name, "name")},
			{"sport_type", text(args.sport_type, "sport_type")},
			{"start_date_local", text(args.start_date_local, "start_date_local")},
			{"elapsed_time", integer(args.elapsed_time, "elapsed_time", 1, MAX_SAFE_INTEGER)},
		}
		assert(string.match(args.sport_type, "^%a+$"), "sport_type must be a Strava sport type such as Run")
		if args.description ~= nil then
			assert(type(args.description) == "string", "description must be a string")
			table.insert(fields, {"description", args.description})
		end
		if args.distance ~= nil then
			assert(type(args.distance) == "number" and args.distance >= 0 and args.distance < math.huge, "distance must be a number of meters")
			table.insert(fields, {"distance", tostring(args.distance)})
		end
		for _, flag in {"trainer", "commute"} do
			if args[flag] ~= nil then table.insert(fields, {flag, if boolean(args[flag], flag) then "1" else "0"}) end
		end
		if args.tags ~= nil then
			assert(args.commute == nil, "tags cannot be combined with commute; use tags.Commute")
			tagFields(fields, tags(args.tags))
		end
		return call("createActivity", {method = "POST", path = "/activities", form = fields, expect = "object", idempotent = false})
	end

	help.functions.updateActivityById = {
		description = [[Changes an activity's name, description, sport_type, gear (gear_id, or "none" to clear it),
commute, trainer, hide_from_home (mute from followers' feeds) or tags, and returns the detailed
activity. Fields left out stay unchanged. tags cannot be combined with commute.]],
		inputSchema = {
			type = "object",
			properties = {id = ID, name = {type = "string", minLength = 1}, description = {type = "string"}, sport_type = SPORT_TYPE,
				gear_id = {type = "string", pattern = "^[A-Za-z0-9]+$"}, commute = {type = "boolean"}, trainer = {type = "boolean"},
				hide_from_home = {type = "boolean"}, tags = TAG_OBJECT},
			required = {"id"},
			minProperties = 2,
			additionalProperties = false,
			examples = {{id = 16532880011, name = "Sunrise tempo run", description = "6 x 1 km at threshold"},
				{id = 16532880011, gear_id = "none", tags = {WithPet = true}}} :: {any},
		},
		annotations = IDEMPOTENT,
	}
	function exports.updateActivityById(input: any): Options
		local args = options(input, "updateActivityById", {"id", "name", "description", "sport_type", "gear_id", "commute", "trainer", "hide_from_home", "tags"})
		local path = "/activities/" .. id(args.id, "id")
		args.id = nil
		assert(next(args) ~= nil, "updateActivityById needs at least one field to change")
		if args.name ~= nil then text(args.name, "name") end
		assert(args.description == nil or type(args.description) == "string", "description must be a string")
		if args.sport_type ~= nil then assert(string.match(text(args.sport_type, "sport_type"), "^%a+$"), "sport_type must be a Strava sport type such as Run") end
		if args.gear_id ~= nil then gearId(args.gear_id, "gear_id") end
		for _, flag in {"commute", "trainer", "hide_from_home"} do
			if args[flag] ~= nil then boolean(args[flag], flag) end
		end
		if args.tags ~= nil then
			assert(args.commute == nil, "tags cannot be combined with commute; use tags.Commute")
			tags(args.tags)
		end
		return call("updateActivityById", {method = "PUT", path = path, json = args, expect = "object", idempotent = true})
	end

	help.functions.starSegment = {
		description = "Stars (starred = true) or unstars a segment for the athlete and returns the detailed segment.",
		inputSchema = {type = "object", properties = {id = ID, starred = {type = "boolean"}}, required = {"id", "starred"},
			additionalProperties = false, examples = {{id = 229781, starred = true}}},
		annotations = IDEMPOTENT,
	}
	function exports.starSegment(input: any): Options
		local args = options(input, "starSegment", {"id", "starred"})
		local path = "/segments/" .. id(args.id, "id") .. "/starred"
		return call("starSegment", {method = "PUT", path = path, form = {{"starred", tostring(boolean(args.starred, "starred"))}},
			expect = "object", idempotent = true})
	end

	help.functions.createUpload = {
		description = [[Imports an activity file from the session file at path and returns the upload status {id, id_str,
external_id, error, status, activity_id}. data_type is the file's format (fit, tcx or gpx, with .gz
when gzipped; json for Strava's strength-training format). Strava processes the file
asynchronously: poll getUploadById with id_str, at most once a second, until activity_id or error
is set. external_id defaults to the file name; Strava refuses a file it already imported.]],
		inputSchema = {
			type = "object",
			properties = {path = {type = "string", minLength = 1, description = "Session file to import."},
				data_type = {type = "string", enum = DATA_TYPES}, name = {type = "string", minLength = 1}, description = {type = "string"},
				sport_type = SPORT_TYPE, trainer = {type = "boolean"}, commute = {type = "boolean"},
				external_id = {type = "string", minLength = 1}, tags = TAG_OBJECT},
			required = {"path", "data_type"},
			additionalProperties = false,
			examples = {{path = "imports/morning-ride.fit", data_type = "fit", name = "Morning ride", external_id = "garmin-20261116-0730"}},
		},
		annotations = WRITE,
	}
	function exports.createUpload(input: any): Options
		local args = options(input, "createUpload", {"path", "data_type", "name", "description", "sport_type", "trainer", "commute", "external_id", "tags"})
		local path = text(args.path, "path")
		local dataType = text(args.data_type, "data_type")
		assert(table.find(DATA_TYPES, dataType), "data_type must be one of " .. table.concat(DATA_TYPES, ", "))
		local fields: {Field} = {{"data_type", dataType}}
		for _, field in {"name", "description", "sport_type", "external_id"} do
			if args[field] ~= nil then
				if field == "description" then assert(type(args[field]) == "string", "description must be a string") else text(args[field], field) end
				table.insert(fields, {field, args[field]})
			end
		end
		if args.sport_type ~= nil then assert(string.match(args.sport_type, "^%a+$"), "sport_type must be a Strava sport type such as Run") end
		for _, flag in {"trainer", "commute"} do
			if args[flag] ~= nil then table.insert(fields, {flag, if boolean(args[flag], flag) then "1" else "0"}) end
		end
		if args.tags ~= nil then
			assert(args.commute == nil, "tags cannot be combined with commute; use tags.Commute")
			tagFields(fields, tags(args.tags))
		end
		assert(await(fs.exists(path)) and await(fs.stat(path)).isFile, "path " .. path .. " is not a session file")
		local filename = string.match(path, "[^/]+$") or path
		local parts: {any} = {}
		for _, field in fields do table.insert(parts, {name = field[1], body = field[2]}) end
		table.insert(parts, {name = "file", filename = filename, contentType = "application/octet-stream", body = fs.open(path, "r")})
		return call("createUpload", {method = "POST", path = "/uploads", multipart = parts, expect = "object", idempotent = false})
	end

	help.functions.getUploadById = {
		description = [[The status of an upload from createUpload: {id, id_str, external_id, error, status, activity_id}.
activity_id is set once the activity exists; error explains a failed import, such as a duplicate.]],
		inputSchema = {type = "object", properties = {uploadId = ID}, required = {"uploadId"}, additionalProperties = false,
			examples = {{uploadId = "15467223451"}}},
		annotations = READ,
	}
	function exports.getUploadById(input: any): Options
		local args = options(input, "getUploadById", {"uploadId"})
		return get("getUploadById", "/uploads/" .. id(args.uploadId, "uploadId"))
	end
end

return exports
