-- A connection with Write access: manual activities, uploads, activity and athlete updates, starring.
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, access = {data = "write"}, config = {}, auth_method = "oauth", auth_config = {}},
	configure = function()
		requests, responses = {}, {}
		fs = fixture.files()
		http = {request = function(req)
			for name in req.headers or {} do assert(string.lower(name) ~= "authorization", "the proxy injects Authorization") end
			if req.url == "https://www.strava.com/api/v3/uploads" then
				assert(type(req.body) ~= "string", "the activity file must reach HTTP as a stream")
			end
			if req.body ~= nil and type(req.body) ~= "string" then req.body = await(req.body:readAll()) end
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.method .. " " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "{}")})
		end}
	end,
	run = function(c)
		local API = "https://www.strava.com/api/v3"
		local FORM = "application/x-www-form-urlencoded"
		local function last(method: string, href: string, contentType: string?): string
			local req = requests[#requests]
			assert(req.method == method and req.url == href, req.method .. " " .. req.url)
			if contentType then assert(req.headers["Content-Type"][1] == contentType, req.headers["Content-Type"][1]) end
			return req.body
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
		assert(table.concat(names, ",") == "createActivity,createUpload,getActivityById,getActivityStreams,getClubById,getCommentsByActivityId,"
			.. "getEffortsBySegmentId,getGearById,getKudoersByActivityId,getLapsByActivityId,getLoggedInAthlete,getLoggedInAthleteActivities,"
			.. "getLoggedInAthleteClubs,getLoggedInAthleteStarredSegments,getLoggedInAthleteZones,getRouteAsGPX,getRouteAsTCX,getRouteById,"
			.. "getRouteStreams,getRoutesByAthleteId,getSegmentById,getSegmentEffortById,getSegmentEffortStreams,getSegmentStreams,getStats,"
			.. "getUploadById,getZonesByActivityId,starSegment,updateActivityById,updateLoggedInAthlete", "write got " .. table.concat(names, ","))

		-- createActivity posts Strava's form fields; booleans become 1/0 and tags tags[Name]=bool.
		responses = {{status = 201, body = '{"id":16532880099,"name":"Lunch run","sport_type":"Run"}'}, {status = 201, body = '{"id":16532880100}'}}
		local created = c.createActivity({name = "Lunch run & laps", sport_type = "Run", start_date_local = "2026-11-16T12:15:00Z", elapsed_time = 2700,
			distance = 8000.5, description = "Easy", trainer = false, commute = true})
		assert(created.id == 16532880099)
		assert(last("POST", API .. "/activities", FORM) == "name=Lunch%20run%20%26%20laps&sport_type=Run&start_date_local=2026-11-16T12%3A15%3A00Z"
			.. "&elapsed_time=2700&description=Easy&distance=8000.5&trainer=0&commute=1", requests[#requests].body)
		c.createActivity({name = "Gym", sport_type = "WeightTraining", start_date_local = "2026-11-16T18:00:00Z", elapsed_time = 3600,
			tags = {Recovery = true, WithPet = false}})
		assert(last("POST", API .. "/activities", FORM) == "name=Gym&sport_type=WeightTraining&start_date_local=2026-11-16T18%3A00%3A00Z"
			.. "&elapsed_time=3600&tags%5BRecovery%5D=true&tags%5BWithPet%5D=false", requests[#requests].body)

		-- updateActivityById sends only the given fields as JSON.
		responses = {{body = '{"id":16532880011,"name":"Sunrise tempo"}'}}
		local options = {id = 16532880011, name = "Sunrise tempo", gear_id = "none", hide_from_home = true, tags = {WithPet = true}}
		assert(c.updateActivityById(options).name == "Sunrise tempo")
		assert(options.id == 16532880011, "updateActivityById changed the caller's options")
		local sent = json.decode(last("PUT", API .. "/activities/16532880011", "application/json"))
		assert(sent.name == "Sunrise tempo" and sent.gear_id == "none" and sent.hide_from_home == true and sent.tags.WithPet == true and sent.id == nil)

		responses = {{body = '{"id":134815,"weight":71.5}'}, {body = '{"id":229781,"starred":false}'}}
		assert(c.updateLoggedInAthlete({weight = 71.5}).weight == 71.5)
		assert(last("PUT", API .. "/athlete", FORM) == "weight=71.5")
		assert(c.starSegment({id = 229781, starred = false}).starred == false)
		assert(last("PUT", API .. "/segments/229781/starred", FORM) == "starred=false")

		-- createUpload streams the session file as the multipart file part, with the form fields.
		local file = fs.open("imports/morning-ride.fit", "w")
		file:write("fake-fit-bytes")
		await(file:close())
		responses = {{status = 201, body = '{"id":15467223451,"id_str":"15467223451","external_id":"garmin-1","error":null,"status":"Your activity is still being processed.","activity_id":null}'},
			{body = '{"id":15467223451,"id_str":"15467223451","error":null,"status":"Your activity is ready.","activity_id":16532880123}'}}
		local upload = c.createUpload({path = "imports/morning-ride.fit", data_type = "fit", name = "Morning ride", external_id = "garmin-1", trainer = true, tags = {Commute = true}})
		assert(upload.id_str == "15467223451" and upload.activity_id == json.decode("null"))
		local req = requests[#requests]
		assert(req.method == "POST" and req.url == API .. "/uploads")
		assert(string.match(req.headers["Content-Type"][1], "^multipart/form%-data; boundary=") ~= nil, req.headers["Content-Type"][1])
		for _, part in {'name="data_type"\r\n\r\nfit\r\n', 'name="name"\r\n\r\nMorning ride\r\n', 'name="external_id"\r\n\r\ngarmin-1\r\n',
			'name="trainer"\r\n\r\n1\r\n', 'name="tags[Commute]"\r\n\r\ntrue\r\n', 'name="file"; filename="morning-ride.fit"', "fake-fit-bytes"} do
			assert(string.find(req.body, part, 1, true), "upload body lacks " .. part)
		end
		assert(c.getUploadById({uploadId = upload.id_str}).activity_id == 16532880123)
		assert(last("GET", API .. "/uploads/15467223451") == nil)

		-- Invalid input never reaches Strava.
		rejects("name must be a nonempty string", c.createActivity, {sport_type = "Run", start_date_local = "2026-11-16T12:15:00Z", elapsed_time = 60})
		rejects("elapsed_time must be an integer", c.createActivity, {name = "x", sport_type = "Run", start_date_local = "2026-11-16T12:15:00Z", elapsed_time = 0})
		rejects("sport_type must be a Strava sport type", c.createActivity, {name = "x", sport_type = "Run&x=1", start_date_local = "t", elapsed_time = 60})
		rejects("tags cannot be combined with commute", c.createActivity, {name = "x", sport_type = "Run", start_date_local = "t", elapsed_time = 60, commute = true, tags = {Commute = true}})
		rejects("tags keys must be among", c.updateActivityById, {id = 1, tags = {Race = true}})
		rejects("tags cannot be combined with commute", c.updateActivityById, {id = 1, commute = true, tags = {Commute = false}})
		rejects("tags cannot be combined with commute", c.createUpload, {path = "imports/morning-ride.fit", data_type = "fit", commute = false, tags = {WithPet = true}})
		rejects("gear_id must be a gear ID", c.updateActivityById, {id = 1, gear_id = "b1/x"})
		rejects("sport_type must be a Strava sport type", c.updateActivityById, {id = 1, sport_type = "Run Club"})
		rejects("sport_type must be a Strava sport type", c.createUpload, {path = "imports/morning-ride.fit", data_type = "fit", sport_type = "Ride&x"})
		rejects("needs at least one field to change", c.updateActivityById, {id = 1})
		rejects("weight must be a number of kilograms", c.updateLoggedInAthlete, {weight = 0})
		rejects("starred must be a boolean", c.starSegment, {id = 1, starred = "true"})
		rejects("data_type must be one of", c.createUpload, {path = "imports/morning-ride.fit", data_type = "zip"})
		rejects("path missing.fit is not a session file", c.createUpload, {path = "missing.fit", data_type = "fit"})
		rejects("unknown option activity_type", c.createUpload, {path = "imports/morning-ride.fit", data_type = "fit", activity_type = "ride"})
		assert(#responses == 0)
	end,
}
