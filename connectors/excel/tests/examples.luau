-- Every documented example runs as a real call against a permissive Graph mock; read-write documents
-- every operation.
local function operations(node: any, prefix: string, names: {string}): {string}
	for _, name in node.functions do table.insert(names, prefix .. name) end
	for _, name in node.namespaces do operations(node[name], prefix .. name .. ".", names) end
	return names
end
local function run(c)
	local names = operations(c, "", {})
	for _, name in names do fixture.example(name) end
	for _, name in {"tables.list", "names.list", "ranges.get", "ranges.update"} do fixture.example(name, 2) end
	for index = 3, 4 do fixture.example("ranges.get", index) end
	assert(calls == #names + 6, "examples made " .. calls .. " requests")
end
local function configure()
	calls = 0
	http = {request = function(req)
		calls += 1
		assert(string.find(req.url, "https://graph.microsoft.com/v1.0/me/", 1, true) == 1, req.url)
		return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"id":"x","value":[]}')})
	end}
end
local scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}}
return {scenario = scenario, access = {data = "write"}, configure = configure, run = run}
