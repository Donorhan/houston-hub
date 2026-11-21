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
		assert(long.message.body == "Long draft" and long.message.bodyTruncated == true and #requests == 1, "a body stored as an attachment falls back to the snippet, marked truncated, without Messages access")

		local reply = {id = "d1", message = {id = "m1", threadId = "t9", payload = {headers = {
			{name = "Subject", value = "Re: Plans"}, {name = "In-Reply-To", value = "<o1@example.com>"}, {name = "References", value = "<o0@example.com> <o1@example.com>"},
		}}}}
		responses = {json.encode(reply), '{"id":"d1","message":{"id":"m2","threadId":"t9"}}'}
		c.updateDraft({id = "d1", to = "ana@example.com", text = "Edited"})
		assert(requests[2].method == "GET" and requests[2].url == "https://gmail.googleapis.com/gmail/v1/users/me/drafts/d1?format=metadata", requests[2].url)
		local body = requests[3].body
		assert(requests[3].method == "PUT" and string.find(body, '{"message":{"threadId":"t9"}}', 1, true), "an edited draft stays in its thread")
		for _, line in {"Subject: Re: Plans\r\n", "In-Reply-To: <o1@example.com>\r\n", "References: <o0@example.com> <o1@example.com>\r\n"} do
			assert(string.find(body, line, 1, true), "an edited draft keeps " .. line)
		end
		assert(#requests == 3 and #responses == 0)
	end,
}
