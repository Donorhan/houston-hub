return {
	scenario = {
		publisher = {composio_auth_config_id = "ac_fixture", composio_api_key = "fixture-secret"},
		config = {}, auth_method = "composio", auth_config = {},
	},
	access = {messages = "read", drafts = "create", sending = "none"},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			table.insert(requests, req.url)
			assert(#responses > 0, "unexpected request: " .. req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(table.remove(responses, 1))})
		end}
	end,
	run = function(c)
		local API = "https://gmail.googleapis.com/gmail/v1/users/me"
		assert(type(c.listMessages) == "function" and c.sendMessage == nil and c.updateDraft == nil)
		local original = {id = "o1", threadId = "t9", payload = {headers = {
			{name = "From", value = "ana@example.com"}, {name = "To", value = "reader@example.com, bo@example.com"}, {name = "Message-ID", value = "<o1@example.com>"},
		}}}
		responses = {json.encode(original), '{"emailAddress":"Reader@example.com"}', '{"id":"d1"}'}
		c.createDraft({inReplyTo = "o1", replyAll = true, text = "Noted"})
		assert(requests[2] == API .. "/profile", "Composio's full Gmail grant reads the mailbox address from the profile: " .. requests[2])
		assert(#requests == 3 and #responses == 0)
	end,
}
