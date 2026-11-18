return {
	scenario = {config = {environment = "production", client_id = "fixture-app"}, access = {data = "read"}, auth_method = "oauth", auth_config = {}},
	configure = function()
		requests = {}
		http = {request = function(req)
			table.insert(requests, req)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"persons":[{"id":"P1"}],"sourceDescriptions":[]}')})
		end}
	end,
	run = function(c)
		local person = c.readPerson({pid = "P1"})
		assert(person.data.persons[1].id == "P1")
		local composed = fixture.example("createNameSegments")
		assert(composed.statusCode == 200 and requests[#requests].method == "POST" and requests[#requests].url == "https://api.familysearch.org/platform/names/segments")
		local matches = fixture.example("performPersonMatchesByExample")
		assert(matches.data.persons[1].id == "P1" and requests[#requests].method == "POST" and string.find(requests[#requests].url, "https://api.familysearch.org/platform/tree/matches", 1, true) == 1)
		assert(c.createPerson == nil and c.createPartnerAccount == nil and c.createMemories == nil)
		assert(c.setCurrentTree == nil and c.deleteUserHistory == nil)
		assert(#requests == 3)
	end,
}
