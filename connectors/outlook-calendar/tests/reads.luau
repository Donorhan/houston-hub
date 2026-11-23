return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "read"},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			assert(req.headers == nil or req.headers.Authorization == nil, "the proxy injects Authorization")
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "")})
		end}
	end,
	run = function(c)
		local API = "https://graph.microsoft.com/v1.0/me"
		local LIST = "$select=id%2Csubject%2Cstart%2Cend%2CisAllDay%2Clocation%2Corganizer%2Cattendees%2CshowAs%2CresponseStatus%2CisOrganizer%2CisCancelled%2Ctype%2CseriesMasterId%2ConlineMeeting%2CwebLink%2CbodyPreview%2Ccategories%2Csensitivity"
		local function last() return requests[#requests] end
		local function fails(expected: {string}, fn: (...any) -> any, ...: any)
			local ok, err = pcall(fn, ...)
			assert(not ok, "call succeeded")
			for _, text in expected do assert(string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err)) end
		end

		-- Calendars: the default one, or one named by ID; lists always carry a value array.
		responses = {{body = '{"id":"C0","name":"Calendar","isDefaultCalendar":true}'}, {body = '{"id":"C1","name":"Team"}'}, {body = '{}'}, {body = '{"value":[{"id":"C1"}]}'}}
		assert(c.calendars.get().isDefaultCalendar and last().url == API .. "/calendar", last().url)
		assert(last().headers.Prefer == nil, "calendars take no Prefer header")
		assert(c.calendars.get({calendarId = "AAMk-_=", select = {"id", "name"}}).name == "Team")
		assert(last().url == API .. "/calendars/AAMk-_%3D?$select=id,name", last().url)
		assert(json.encode(c.calendars.list({top = 50}).value) == "[]" and last().url == API .. "/calendars?$top=50", last().url)
		local link = "https://graph.microsoft.com/v1.0/me/calendars?$top=50&$skip=50"
		assert(c.calendars.list({nextLink = link}).value[1].id == "C1" and last().url == link, last().url)

		-- Calendar views take a time range, summary fields and start order by default, with text bodies
		-- and times in the requested zone.
		local nextLink = "https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=2026-11-09T00%3a00%3a00.0000000&endDateTime=2026-11-16T00%3a00%3a00.0000000&%24select=id&%24orderby=start%2fdateTime&%24top=1&%24skip=1"
		responses = {
			{body = '{"value":[{"id":"E1","subject":"Standup","type":"occurrence","seriesMasterId":"S1"}],"@odata.nextLink":"' .. nextLink .. '"}'},
			{body = '{"value":[]}'}, {body = '{}'},
		}
		local page = c.events.list({startDateTime = "2026-11-09T00:00:00Z", endDateTime = "2026-11-16T00:00:00Z", timeZone = "Europe/Paris", top = 1})
		assert(page.value[1].seriesMasterId == "S1" and page["@odata.nextLink"] == nextLink)
		assert(last().url == API .. "/calendarView?startDateTime=2026-11-09T00%3A00%3A00Z&endDateTime=2026-11-16T00%3A00%3A00Z&" .. LIST .. "&$orderby=start%2FdateTime&$top=1", last().url)
		assert(table.concat(last().headers.Prefer, ";") == 'outlook.timezone="Europe/Paris";outlook.body-content-type="text"', table.concat(last().headers.Prefer, ";"))
		-- nextLink keeps the range; the Prefer options repeat on every page.
		assert(#c.events.list({nextLink = nextLink, timeZone = "Europe/Paris"}).value == 0)
		assert(last().url == nextLink and last().headers.Prefer[1] == 'outlook.timezone="Europe/Paris"', last().url)
		-- Graph may name the calendar by OData key; the route takes its path form.
		responses = {{body = '{"value":[{"id":"E2"}]}'}, {body = '{"value":[]}'}, {body = '{}'}}
		assert(c.events.list({nextLink = "https://graph.microsoft.com/v1.0/me/calendars('C1')/calendarView?startDateTime=2026-11-01&endDateTime=2026-12-01&%24skip=10"}).value[1].id == "E2")
		assert(last().url == API .. "/calendars/C1/calendarView?startDateTime=2026-11-01&endDateTime=2026-12-01&%24skip=10", last().url)
		assert(json.encode(c.events.list({calendarId = "C1", startDateTime = "2026-11-01", endDateTime = "2026-12-01", filter = "isCancelled eq false",
			select = "id,subject,body", orderby = "subject", bodyFormat = "html"}).value) == "[]")
		assert(last().url == API .. "/calendars/C1/calendarView?startDateTime=2026-11-01&endDateTime=2026-12-01&$select=id%2Csubject%2Cbody&$filter=isCancelled%20eq%20false&$orderby=subject", last().url)
		assert(#last().headers.Prefer == 1 and last().headers.Prefer[1] == 'outlook.body-content-type="html"')

		responses = {{body = '{"id":"S1","type":"seriesMaster","recurrence":{"pattern":{"type":"weekly"}}}'}, {body = '{"value":[{"id":"E1"},{"id":"E2"}]}'}}
		assert(c.events.get({id = "AAMk-_=", timeZone = "Pacific Standard Time"}).recurrence.pattern.type == "weekly")
		assert(last().url == API .. "/events/AAMk-_%3D" and last().headers.Prefer[1] == 'outlook.timezone="Pacific Standard Time"', last().url)
		assert(#c.events.listInstances({id = "S1", startDateTime = "2026-11-01T00:00:00Z", endDateTime = "2027-01-01T00:00:00Z", top = 2}).value == 2)
		assert(last().url == API .. "/events/S1/instances?startDateTime=2026-11-01T00%3A00%3A00Z&endDateTime=2027-01-01T00%3A00%3A00Z&" .. LIST .. "&$top=2", last().url)
		-- Events of a shared calendar are reached through that calendar.
		responses = {{body = '{"id":"E5"}'}, {body = '{"value":[]}'}}
		assert(c.events.get({calendarId = "C-1=", id = "E5"}).id == "E5" and last().url == API .. "/calendars/C-1%3D/events/E5", last().url)
		c.events.listInstances({calendarId = "C1", id = "S1", startDateTime = "2026-11-01", endDateTime = "2026-12-01"})
		assert(last().url == API .. "/calendars/C1/events/S1/instances?startDateTime=2026-11-01&endDateTime=2026-12-01&" .. LIST, last().url)
		local instances = "https://graph.microsoft.com/v1.0/me/events('S1')/instances?startDateTime=2026-11-01T00%3a00%3a00Z&endDateTime=2027-01-01T00%3a00%3a00Z&%24top=2&%24skip=2"
		responses = {{body = '{"value":[]}'}}
		assert(json.encode(c.events.listInstances({nextLink = instances}).value) == "[]")
		assert(last().url == "https://graph.microsoft.com/v1.0/me/events/S1/instances?startDateTime=2026-11-01T00%3a00%3a00Z&endDateTime=2027-01-01T00%3a00%3a00Z&%24top=2&%24skip=2", last().url)

		responses = {{body = '{"value":[{"scheduleId":"ana@example.com","availabilityView":"0220","scheduleItems":[]}]}'}}
		local schedule = c.calendars.getSchedule({schedules = {"ana@example.com"}, startTime = {dateTime = "2026-11-12T08:00:00", timeZone = "Europe/Paris"},
			endTime = {dateTime = "2026-11-12T10:00:00", timeZone = "Europe/Paris"}, availabilityViewInterval = 30, timeZone = "Europe/Paris"})
		assert(schedule.value[1].availabilityView == "0220" and last().method == "POST" and last().url == API .. "/calendar/getSchedule", last().url)
		local body = json.decode(last().body)
		assert(body.schedules[1] == "ana@example.com" and body.availabilityViewInterval == 30 and body.timeZone == nil and body.startTime.timeZone == "Europe/Paris")
		assert(#last().headers.Prefer == 1 and last().headers.Prefer[1] == 'outlook.timezone="Europe/Paris"' and last().headers["Content-Type"][1] == "application/json")
		-- A schedule Graph cannot read reports its error in place; an empty reply still carries value.
		responses = {{body = '{"value":[{"scheduleId":"bo@other.test","error":{"message":"Cannot read","responseCode":"5009"}}]}'}, {body = '{}'}}
		local window = {schedules = {"bo@other.test"}, startTime = {dateTime = "2026-11-12T08:00:00", timeZone = "UTC"}, endTime = {dateTime = "2026-11-12T10:00:00", timeZone = "UTC"}}
		assert(c.calendars.getSchedule(window).value[1].error.responseCode == "5009" and last().headers.Prefer == nil)
		local empty = c.calendars.getSchedule(window)
		assert(json.encode(empty.value) == "[]", "calendars.getSchedule returned " .. json.encode(empty))

		-- Invalid input never reaches the network.
		local before = #requests
		fails({"startDateTime must be a nonempty string"}, c.events.list, {endDateTime = "2026-11-16T00:00:00Z"})
		fails({"endDateTime must be a nonempty string"}, c.events.listInstances, {id = "S1", startDateTime = "2026-11-01T00:00:00Z"})
		fails({"id must be a nonempty string"}, c.events.listInstances, {startDateTime = "2026-11-01T00:00:00Z", endDateTime = "2027-01-01T00:00:00Z"})
		fails({"events.list takes nextLink alone"}, c.events.list, {nextLink = nextLink, top = 5})
		fails({"nextLink must come from the same list"}, c.events.list, {nextLink = "https://graph.microsoft.com/v1.0/me/events?$top=1"})
		fails({"nextLink must come from the same list"}, c.events.listInstances, {nextLink = "https://graph.microsoft.com/v1.0/me/events/S1/attachments?$top=1"})
		fails({"nextLink may carry only paging options"}, c.events.list, {nextLink = nextLink .. "&$expand=attachments"})
		fails({"nextLink must be an @odata.nextLink"}, c.events.list, {nextLink = "https://graph.microsoft.com.evil.test/v1.0/me/calendarView?$skip=1"})
		fails({"timeZone must be a time zone name"}, c.events.get, {id = "E1", timeZone = 'UTC"\r\nX-Evil: 1'})
		fails({"timeZone must be a time zone name"}, c.events.list, {nextLink = nextLink, timeZone = "UTC\\"})
		fails({"bodyFormat must be text or html"}, c.events.get, {id = "E1", bodyFormat = "rtf"})
		fails({"events.get received an unknown option"}, c.events.get, {id = "E1", expand = "attachments"})
		fails({"calendars.getSchedule requires schedules"}, c.calendars.getSchedule, {schedules = {}, startTime = {}, endTime = {}})
		fails({"calendars.getSchedule requires startTime and endTime"}, c.calendars.getSchedule, {schedules = {"ana@example.com"}})
		fails({"calendars.get received an unknown option"}, c.calendars.get, {top = 1})
		assert(#requests == before, "invalid input reached the network")

		-- Graph errors keep the status, code and message; throttling is retryable.
		responses = {
			{status = 404, body = '{"error":{"code":"ErrorItemNotFound","message":"The specified object was not found in the store."}}'},
			{status = 429, headers = {["retry-after"] = {"7"}}, body = '{"error":{"code":"ApplicationThrottled","message":"Too many requests"}}'},
			{status = 403, body = '{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}'},
			{status = 200, body = "[]"},
		}
		fails({"Microsoft Graph HTTP 404 (ErrorItemNotFound)", '"retryable":false'}, c.events.get, {id = "missing"})
		fails({"HTTP 429 (ApplicationThrottled)", "Retry-After: 7", '"retryable":true'}, c.calendars.get)
		fails({"HTTP 403 (ErrorAccessDenied)", '"retryable":false'}, c.calendars.list)
		fails({"invalid JSON object"}, c.calendars.get)
	end,
}
