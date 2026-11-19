return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {messages = "read", drafts = "none", sending = "none"},
	configure = function()
		http = {request = function(req)
			assert(req.url == "https://gmail.googleapis.com/gmail/v1/users/me/labels", req.url)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"labels":[]}')})
		end}
	end,
	run = function(c)
		local names = {}
		for name in c do table.insert(names, name) end
		table.sort(names)
		assert(table.concat(names, ",") == "getAttachment,getLabel,getMessage,getMessages,getThread,listHistory,listLabels,listMailFolders,listMessages,listThreads", "read got " .. table.concat(names, ","))
		assert(not pcall(c.listMailFolders, "unexpected"))
		local folders = c.listMailFolders()
		assert(json.encode(folders) == "[]", "empty folders must remain a JSON array")
	end,
}
