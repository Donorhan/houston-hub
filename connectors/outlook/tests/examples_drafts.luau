-- Every documented example of a Draft connection runs as a real call against a
-- permissive Graph mock.
local function operations(node: any, prefix: string, names: {string}): {string}
	for _, name in node.functions do table.insert(names, prefix .. name) end
	for _, name in node.namespaces do operations(node[name], prefix .. name .. ".", names) end
	return names
end
local function run(c)
	local file = fs.open("report.pdf", "w")
	file:write("%PDF")
	await(file:close())
	local names = operations(c, "", {})
	for _, name in names do fixture.example(name) end
	for _, name in {"messages.list", "messages.get"} do fixture.example(name, 2) end
	assert(calls >= #names + 2, "an example made no request")
end
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "draft"},
	configure = function()
		calls = 0
		fs = fixture.files()
		http = {request = function(req)
			calls += 1
			assert(string.find(req.url, "https://graph.microsoft.com/v1.0/me", 1, true) == 1, req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"id":"x","name":"x","isDraft":true,"value":[]}')})
		end}
	end,
	run = run,
}
