-- Every documented example runs as a real call against a permissive Graph mock.
local function operations(node: any, prefix: string, names: {string}): {string}
	for _, name in node.functions do table.insert(names, prefix .. name) end
	for _, name in node.namespaces do operations(node[name], prefix .. name .. ".", names) end
	return names
end
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "write"},
	configure = function()
		calls = 0
		fs = fixture.files()
		http = {request = function(req)
			if type(req.body) == "userdata" then req.body = await(req.body:readAll()) end
			calls += 1
			assert(string.find(req.url, "https://graph.microsoft.com/v1.0/", 1, true) == 1, req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"id":"x","name":"x","size":1,"value":[]}')})
		end}
	end,
	run = function(c)
		local file = fs.open("plan.pdf", "w")
		file:write("%PDF")
		await(file:close())
		local names = operations(c, "", {})
		for _, name in names do fixture.example(name) end
		local second = {"search", "sites.get", "files.getDrive", "files.get", "files.download", "files.createFolder", "files.upload"}
		for _, name in second do fixture.example(name, 2) end
		assert(calls == #names + #second, "an example made no request")
	end,
}
