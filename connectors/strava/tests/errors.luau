-- Strava errors keep their message and details, explain missing permissions and rate limits, and
-- are retryable only when repeating the call is safe. Nothing is retried by the connector.
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {access = "read-write"}, auth_method = "oauth", auth_config = {}},
	configure = function()
		calls = 0
		fs = fixture.files()
		status, payload, responseHeaders = 200, "{}", {}
		http = {request = function(req)
			calls += 1
			return fixture.operation({statusCode = status, headers = responseHeaders, body = fixture.reader(payload)})
		end}
	end,
	run = function(c)
		local RUN = {name = "Run", sport_type = "Run", start_date_local = "2026-11-16T12:15:00Z", elapsed_time = 60}
		local file = fs.open("ride.gpx", "w")
		file:write("<gpx/>")
		await(file:close())
		local function upstream(code: number, body: string, headers: {[string]: {string}}, fn: (any) -> any, input: any, expected: {string}, absent: {string}?): string
			status, payload, responseHeaders = code, body, headers
			local before = calls
			local ok, err = pcall(fn, input)
			local message = tostring(err)
			assert(not ok, "call succeeded")
			for _, text in expected do assert(string.find(message, text, 1, true), "missing " .. text .. " in " .. message) end
			for _, text in absent or {} do assert(not string.find(message, text, 1, true), "unexpected " .. text .. " in " .. message) end
			assert(calls == before + 1, "a failed call was repeated")
			return message
		end

		upstream(401, '{"message":"Authorization Error","errors":[{"resource":"AccessToken","field":"activity:read_permission","code":"missing"}]}', {},
			c.getLoggedInAthleteActivities, nil, {"Strava HTTP 401: Authorization Error (AccessToken activity:read_permission missing)",
				"the athlete did not grant activity:read_permission: reconnect Strava and keep every permission ticked", '"retryable":false'})
		upstream(401, '{"message":"Authorization Error","errors":[{"resource":"Athlete","field":"access_token","code":"invalid"}]}', {},
			c.getLoggedInAthlete, nil, {"Strava HTTP 401: Authorization Error (Athlete access_token invalid)", "reconnect Strava if the athlete revoked", '"retryable":false'})
		upstream(404, '{"message":"Record Not Found","errors":[{"resource":"Activity","field":"id","code":"invalid"}]}', {},
			c.getActivityById, {id = 1}, {"Strava HTTP 404: Record Not Found (Activity id invalid)", '"retryable":false'}, {"reconnect"})
		upstream(403, '{"message":"Forbidden","errors":[]}', {}, c.getSegmentEffortById, {id = 1}, {"Strava HTTP 403: Forbidden", '"retryable":false'})
		local long = upstream(400, json.encode({message = string.rep("x", 1000), errors = {{resource = string.rep("r", 500), field = "name", code = "invalid"}}}), {},
			c.updateActivityById, {id = 1, name = "x"}, {"Strava HTTP 400: " .. string.rep("x", 300), string.rep("r", 100) .. " name invalid"}, {string.rep("x", 301), string.rep("r", 101)})
		assert(#long < 1000, "error message is not bounded: " .. #long)
		upstream(400, json.encode({message = string.rep("x", 20000)}), {}, c.updateActivityById, {id = 1, name = "x"}, {"Strava HTTP 400", '"retryable":false'}, {"xxx"})
		-- Upload errors may be HTML: tags are dropped and the text kept.
		upstream(400, "<html><body><h1>Bad file</h1> unsupported data</body></html>", {}, c.createActivity, RUN, {"Strava HTTP 400:", "Bad file", "unsupported data"}, {"<h1>"})

		-- The 15-minute limit is retryable after the quarter hour; the daily one is not.
		upstream(429, '{"message":"Rate Limit Exceeded","errors":[{"resource":"Application","field":"rate limit","code":"exceeded"}]}',
			{["x-ratelimit-limit"] = {"200,2000"}, ["x-ratelimit-usage"] = {"214,640"}, ["x-readratelimit-limit"] = {"100,1000"}, ["x-readratelimit-usage"] = {"101,320"}},
			c.getLoggedInAthlete, nil, {"Strava HTTP 429: Rate Limit Exceeded", "requests 214/200 in 15 minutes, 640/2000 today", "non-upload requests 101/100 in 15 minutes, 320/1000 today",
				"the 15-minute limit resets on the quarter hour", '"retryable":true'})
		upstream(429, '{"message":"Rate Limit Exceeded"}', {["x-ratelimit-limit"] = {"200,2000"}, ["x-ratelimit-usage"] = {"12,1990"},
			["x-readratelimit-limit"] = {"100,1000"}, ["x-readratelimit-usage"] = {"10,1000"}},
			c.getLoggedInAthlete, nil, {"non-upload requests 10/100 in 15 minutes, 1000/1000 today", "the daily limit resets at midnight UTC", '"retryable":false'})
		upstream(429, "", {["x-ratelimit-limit"] = {"bogus"}}, c.getLoggedInAthlete, nil, {"Strava HTTP 429", '"retryable":true'}, {"today"})

		-- Server errors are retryable for reads and updates, never for creates that may have applied.
		upstream(500, '{"message":"Internal Server Error"}', {}, c.getActivityById, {id = 1}, {"Strava HTTP 500: Internal Server Error", '"retryable":true'})
		upstream(503, "", {}, c.updateLoggedInAthlete, {weight = 70}, {"Strava HTTP 503", '"retryable":true'})
		upstream(500, "", {}, c.createActivity, RUN, {"Strava HTTP 500", '"retryable":false'})
		upstream(500, "", {}, c.createUpload, {path = "ride.gpx", data_type = "gpx"}, {"Strava HTTP 500", '"retryable":false'})
		upstream(502, "", {}, c.updateActivityById, {id = 1, name = "x"}, {"Strava HTTP 502", '"retryable":true'})
		upstream(503, "", {}, c.starSegment, {id = 1, starred = true}, {"Strava HTTP 503", '"retryable":true'})
		upstream(502, "", {}, c.getRouteAsGPX, {id = 1, path = "route.gpx"}, {"Strava HTTP 502", '"retryable":true'})
		assert(not await(fs.exists("route.gpx")), "a failed export wrote its file")

		upstream(200, "[" .. string.rep(" ", 8 * 1024 * 1024) .. "]", {}, c.getLoggedInAthleteActivities, nil, {"Strava's response is over 8 MiB", '"retryable":false'})

		-- A success with an unexpected body is refused rather than returned.
		for _, case in {{c.getLoggedInAthlete, nil, "[]", "object"}, {c.getLapsByActivityId, {id = 1}, "{}", "array"},
			{c.getActivityStreams, {id = 1, keys = {"time"}}, "<html></html>", "data"}, {c.getLoggedInAthlete, nil, "not json", "object"}} do
			upstream(200, case[3], {}, case[1], case[2], {"Strava returned an unexpected response instead of JSON " .. case[4], '"retryable":false'})
		end
	end,
}
