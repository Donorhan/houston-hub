return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {messages = "none", drafts = "create", sending = "send"},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(table.remove(responses, 1))})
		end}
	end,
	run = function(c)
		local UPLOAD = "https://gmail.googleapis.com/upload/gmail/v1/users/me"
		local names = {}
		for name in c do table.insert(names, name) end
		table.sort(names)
		assert(table.concat(names, ",") == "createDraft,sendMessage", "got " .. table.concat(names, ","))

		responses = {'{"id":"d1","message":{"id":"m1"}}', '{"id":"s1"}'}
		assert(c.createDraft({to = "ana@example.com", subject = "Hello", text = "Hi Ana"}).id == "d1")
		assert(requests[1].method == "POST" and requests[1].url == UPLOAD .. "/drafts?uploadType=multipart", requests[1].url)
		assert(c.sendMessage({to = "ana@example.com", subject = "Hello", text = "Hi Ana"}).id == "s1")
		assert(requests[2].method == "POST" and requests[2].url == UPLOAD .. "/messages/send?uploadType=multipart", requests[2].url)

		for _, operation in {c.createDraft, c.sendMessage} do
			local ok, err = pcall(operation, {inReplyTo = "o1", text = "Sounds good"})
			assert(not ok and string.find(tostring(err), "needs Messages access set to Read", 1, true), tostring(err))
		end
		assert(#requests == 2 and #responses == 0, "a reply without Messages access reached Google")
	end,
}
