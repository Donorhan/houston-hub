-- A connection with Read access: every read sends Strava's exact route and query, with no credential.
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, access = {data = "read"}, config = {}, auth_method = "oauth", auth_config = {}},
	configure = function()
		requests, responses = {}, {}
		fs = fixture.files()
		http = {request = function(req)
			for name in req.headers or {} do assert(string.lower(name) ~= "authorization", "the proxy injects Authorization") end
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.method .. " " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "{}")})
		end}
	end,
	run = function(c)
		local API = "https://www.strava.com/api/v3"
		local function last(href: string)
			local req = requests[#requests]
			assert(req.method == "GET" and req.url == href and req.body == nil, req.method .. " " .. req.url)
		end
		local function rejects(expected: string, fn: (any) -> any, input: any)
			local before = #requests
			local ok, err = pcall(fn, input)
			assert(not ok and string.find(tostring(err), expected, 1, true), "missing " .. expected .. " in " .. tostring(err))
			assert(#requests == before, "invalid input reached Strava")
		end

		local names = {}
		for name in c do table.insert(names, name) end
		table.sort(names)
		assert(table.concat(names, ",") == "getActivityById,getActivityStreams,getClubById,getCommentsByActivityId,getEffortsBySegmentId,"
			.. "getGearById,getKudoersByActivityId,getLapsByActivityId,getLoggedInAthlete,getLoggedInAthleteActivities,getLoggedInAthleteClubs,"
			.. "getLoggedInAthleteStarredSegments,getLoggedInAthleteZones,getRouteAsGPX,getRouteAsTCX,getRouteById,getRouteStreams,"
			.. "getRoutesByAthleteId,getSegmentById,getSegmentEffortById,getSegmentEffortStreams,getSegmentStreams,getStats,getZonesByActivityId",
			"read got " .. table.concat(names, ","))
		assert(#requests == 0, "initialization and help are offline")

		responses = {{body = '{"id":134815,"firstname":"Marianne","lastname":"T.","bikes":[{"id":"b12345678","name":"EMC"}],"shoes":[]}'}}
		local me = c.getLoggedInAthlete()
		last(API .. "/athlete")
		assert(me.id == 134815 and me.bikes[1].id == "b12345678" and json.encode(me.shoes) == "[]")

		-- Lists keep Strava's arrays, empty or not, and pass paging and time filters as given.
		responses = {{body = '[{"id":16532880011,"name":"Morning Run","sport_type":"Run","distance":8012.4}]'}, {body = "[]"}}
		local activities = c.getLoggedInAthleteActivities({after = 1767225600, before = 1798761600, page = 2, per_page = 200})
		last(API .. "/athlete/activities?before=1798761600&after=1767225600&page=2&per_page=200")
		assert(#activities == 1 and activities[1].distance == 8012.4)
		local empty = c.getLoggedInAthleteActivities()
		last(API .. "/athlete/activities")
		assert(json.encode(empty) == "[]", "an empty page stays an array")

		responses = {{body = '{"id":16532880011,"name":"Morning Run","segment_efforts":[{"id":2922283800928553202,"elapsed_time":321}]}'}}
		local activity = c.getActivityById({id = 16532880011, include_all_efforts = true})
		last(API .. "/activities/16532880011?include_all_efforts=true")
		-- Integers beyond 2^53 - 1 keep every digit as strings; safe ones stay numbers.
		assert(activity.id == 16532880011 and activity.segment_efforts[1].id == "2922283800928553202" and activity.segment_efforts[1].elapsed_time == 321)

		-- Large integers inside strings, and long decimals, are left untouched.
		responses = {{body = '[{"id":12345678987654321,"text":"PR \\"9007199254740993\\" at 12345678901234567 m","cursor":"abc123%20","activity_id":16532880011}]'}}
		local comments = c.getCommentsByActivityId({id = "16532880011", page_size = 50, after_cursor = "abc123%20"})
		last(API .. "/activities/16532880011/comments?page_size=50&after_cursor=abc123%20")
		assert(comments[1].id == "12345678987654321" and comments[1].text == 'PR "9007199254740993" at 12345678901234567 m', comments[1].text)
		responses = {{body = '{"id":1,"value":0.12345678901234567,"exponent":12345678901234567e2,"negative":-9007199254740993,"edge":9007199254740991}'}}
		local mixed = c.getClubById({id = 1})
		assert(mixed.value == 0.12345678901234567 and mixed.exponent == 12345678901234567e2 and mixed.negative == "-9007199254740993" and mixed.edge == 9007199254740991)
		-- A backslash closing a string, and escaped quotes, keep the string state right.
		responses = {{body = '{"a":"x\\\\","id":12345678987654321,"b":"\\u0022 \\" 98765432109876543","c":[-12345678987654321]}'}}
		local escaped = c.getClubById({id = 1})
		assert(escaped.a == "x\\" and escaped.id == "12345678987654321" and escaped.b == '" " 98765432109876543' and escaped.c[1] == "-12345678987654321", json.encode(escaped))
		-- A large page full of strings decodes within the VM's memory.
		responses = {{body = "[" .. string.rep('{"k":"v","x":1},', 120000) .. '{"id":12345678987654321}]'}}
		local large = c.getLoggedInAthleteActivities({per_page = 200})
		assert(#large == 120001 and large[120001].id == "12345678987654321")

		local reads = {
			{c.getLoggedInAthleteZones, nil, "/athlete/zones", '{"heart_rate":{"custom_zones":false,"zones":[]}}'},
			{c.getStats, {id = 134815}, "/athletes/134815/stats", '{"recent_run_totals":{"count":4}}'},
			{c.getLapsByActivityId, {id = 16532880011}, "/activities/16532880011/laps", "[]"},
			{c.getZonesByActivityId, {id = 16532880011}, "/activities/16532880011/zones", '[{"type":"heartrate"}]'},
			{c.getKudoersByActivityId, {id = 16532880011, page = 1, per_page = 30}, "/activities/16532880011/kudos?page=1&per_page=30", '[{"firstname":"Ana","lastname":"B."}]'},
			{c.getActivityStreams, {id = 16532880011, keys = {"time", "heartrate"}}, "/activities/16532880011/streams?keys=time%2Cheartrate&key_by_type=true", '{"time":{"data":[0,1]},"heartrate":{"data":[90,91]}}'},
			{c.getLoggedInAthleteClubs, {per_page = 200}, "/athlete/clubs?per_page=200", "[]"},
			{c.getGearById, {id = "b12345678"}, "/gear/b12345678", '{"id":"b12345678","distance":1234.5}'},
			{c.getRoutesByAthleteId, {id = 134815, page = 3}, "/athletes/134815/routes?page=3", '[{"id":3344425285,"id_str":"3344425285447071234"}]'},
			{c.getRouteById, {id = "3344425285447071234"}, "/routes/3344425285447071234", '{"id":3344425285,"id_str":"3344425285447071234","waypoints":[]}'},
			{c.getRouteStreams, {id = "3344425285447071234"}, "/routes/3344425285447071234/streams", '[{"type":"distance","data":[0,16.8]}]'},
			{c.getSegmentById, {id = 229781}, "/segments/229781", '{"id":229781,"name":"Hawk Hill"}'},
			{c.getLoggedInAthleteStarredSegments, {page = 1}, "/segments/starred?page=1", "[]"},
			{c.getSegmentStreams, {id = 229781, keys = {"latlng"}}, "/segments/229781/streams?keys=latlng&key_by_type=true", '{"latlng":{"data":[[37.8,-122.4]]}}'},
			{c.getEffortsBySegmentId, {segment_id = 229781, start_date_local = "2026-01-01T00:00:00Z", end_date_local = "2026-12-31T23:59:59Z", per_page = 10},
				"/segment_efforts?segment_id=229781&start_date_local=2026-01-01T00%3A00%3A00Z&end_date_local=2026-12-31T23%3A59%3A59Z&per_page=10", "[]"},
			{c.getSegmentEffortById, {id = "2922283800928553202"}, "/segment_efforts/2922283800928553202", '{"id":7,"elapsed_time":321}'},
			{c.getSegmentEffortStreams, {id = "2922283800928553202", keys = {"watts"}}, "/segment_efforts/2922283800928553202/streams?keys=watts&key_by_type=true", '{"watts":{"data":[250]}}'},
		}
		for _, case in reads do
			responses = {{body = case[4]}}
			local result = case[1](case[2])
			last(API .. case[3])
			assert(json.encode(result) == json.encode(json.decode(case[4])), case[3] .. ": " .. json.encode(result))
			-- Every list keeps both empty and populated pages as arrays.
			if string.sub(case[4], 1, 1) == "[" then
				local other = if case[4] == "[]" then '[{"id":1}]' else "[]"
				responses = {{body = other}}
				assert(json.encode(case[1](case[2])) == other, case[3] .. " with " .. other)
			end
		end

		-- Route exports stream to the session file and report its size.
		responses = {{body = '<?xml version="1.0"?><gpx></gpx>'}, {body = "<TrainingCenterDatabase/>"}}
		local gpx = c.getRouteAsGPX({id = "3344425285447071234", path = "routes/loop.gpx"})
		last(API .. "/routes/3344425285447071234/export_gpx")
		assert(gpx.path == "routes/loop.gpx" and gpx.size == 32 and await(fs.open("routes/loop.gpx", "r"):readAll()) == '<?xml version="1.0"?><gpx></gpx>')
		assert(c.getRouteAsTCX({id = 3344425285, path = "loop.tcx"}).size == 25)
		last(API .. "/routes/3344425285/export_tcx")

		-- Invalid input never reaches Strava.
		rejects("unknown option per_page", c.getStats, {id = 1, per_page = 2})
		rejects("id must be a positive integer, or a string of digits", c.getActivityById, {id = "1/../2"})
		rejects("id must be a positive integer, or a string of digits", c.getActivityById, {id = 1.5})
		rejects("id must be a positive integer, or a string of digits", c.getActivityById, {id = 9007199254740992})
		rejects("id must be a positive integer, or a string of digits", c.getActivityById, {})
		rejects("id must be a positive integer, or a string of digits", c.getSegmentEffortById, {id = "9223372036854775808"})
		rejects("per_page must be an integer from 1 to 200", c.getLoggedInAthleteClubs, {per_page = 201})
		rejects("include_all_efforts must be a boolean", c.getActivityById, {id = 1, include_all_efforts = "yes"})
		rejects("keys[2] must be one of", c.getActivityStreams, {id = 1, keys = {"time", "power"}})
		rejects("keys[3] repeats time", c.getActivityStreams, {id = 1, keys = {"time", "watts", "time"}})
		rejects("keys must be an array", c.getSegmentStreams, {id = 1, keys = {}})
		rejects("keys[1] must be one of distance, latlng, altitude", c.getSegmentStreams, {id = 1, keys = {"heartrate"}})
		rejects("id must be a gear ID", c.getGearById, {id = "b1/../x"})
		rejects("path must be a nonempty string", c.getRouteAsGPX, {id = 1})
		rejects("session", c.getRouteAsGPX, {id = 1, path = "../x.gpx"})
		rejects("session", c.getRouteAsTCX, {id = 1, path = "/abs.tcx"})
		rejects("takes one options object", c.getRouteById, 7)
		rejects("after_cursor must be a comment's cursor", c.getCommentsByActivityId, {id = 1, after_cursor = "x&page_size=200"})
		assert(#responses == 0)
	end,
}
