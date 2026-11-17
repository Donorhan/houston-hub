-- Every documented example runs as a real call against a permissive Strava mock; read-write
-- documents every operation. Indexes are tried until a record has no more, so no example is skipped.
local function run(c)
	local names = {}
	for name in c do table.insert(names, name) end
	table.sort(names)
	local file = fs.open("imports/morning-ride.fit", "w")
	file:write("fake-fit-bytes")
	await(file:close())
	local count = 0
	for _, name in names do
		local index = 1
		while true do
			local ok, err = pcall(fixture.example, name, index)
			if not ok then
				assert(index > 1 and string.find(tostring(err), "example index out of range", 1, true), name .. " example " .. index .. ": " .. tostring(err))
				break
			end
			count += 1
			index += 1
		end
	end
	assert(calls == count, "an example made no request, or more than one")
end
-- Paths whose operations return arrays; the others return objects.
local ARRAYS = {"/athlete/activities", "/athlete/clubs", "/athletes/%d+/routes", "/segments/starred", "/segment_efforts%?",
	"/laps$", "/activities/%d+/zones$", "/comments", "/kudos"}
local function configure()
	calls = 0
	fs = fixture.files()
	http = {request = function(req)
		calls += 1
		assert(string.find(req.url, "https://www.strava.com/api/v3/", 1, true) == 1, req.url)
		if req.body ~= nil and type(req.body) ~= "string" then req.body:close() end
		local list = false
		for _, pattern in ARRAYS do list = list or string.find(req.url, pattern) ~= nil end
		return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(if list then "[]" else '{"id":1}')})
	end}
end
local scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}}
return {scenario = scenario, config = {access = "read-write"}, configure = configure, run = run}
