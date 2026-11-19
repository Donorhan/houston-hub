return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {messages = "none", drafts = "manage", sending = "none"},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(table.remove(responses, 1))})
		end}
	end,
	run = function(c)
		local names = {}
		for name in c do table.insert(names, name) end
		table.sort(names)
		assert(table.concat(names, ",") == "createDraft,deleteDraft,getDraft,listDrafts,updateDraft", "got " .. table.concat(names, ","))

		responses = {'{"id":"d2","message":{"id":"m2","snippet":"Long draft","payload":{"mimeType":"text/plain","body":{"attachmentId":"body1","size":900000}}}}'}
		local long = c.getDraft({id = "d2"})
		assert(long.message.body == "Long draft" and #requests == 1, "a body stored as an attachment falls back to the snippet without Messages access")
	end,
}
