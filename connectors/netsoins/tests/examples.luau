-- Every documented example runs as a real call against a NETSoins mock.
return {
	scenario = {publisher = {}, config = {host = "ehpad-test.netsoins.org"}, auth_method = "key", auth_config = {token = "fixture-netsoins-key"}},
	configure = function()
		calls = 0
		http = {request = function(req)
			calls += 1
			local resource = string.match(req.url, "^https://ehpad%-test%.netsoins%.org/webservice%.php/teranga/(%a+)%?")
			assert(resource, req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(
				'{"' .. resource .. '":[{"Uri":"teranga://ehpad-test.netsoins.org/' .. resource .. '#1.a","Libelle":"Direction","Nom":"Martin"}],"WS-Code":0}')})
		end}
	end,
	run = function(netsoins)
		local names = {}
		for name in netsoins do if name ~= "help" then table.insert(names, name) end end
		table.sort(names)
		for _, name in names do fixture.example(name) end
		assert(calls == #names, "an example made no request")
	end,
}
