return {
	scenario = {
		publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret", composio_auth_config_id = "ac_fixture", composio_api_key = "fixture-secret"},
		config = {}, auth_method = "composio", auth_config = {},
	},
	access = {data = "read"},
	configure = function()
		http = {request = function(req)
			assert(req.method == "GET" and req.url == "https://www.googleapis.com/drive/v3/about?fields=user%2CstorageQuota" and req.headers == nil)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"user":{"emailAddress":"reader@example.com"},"storageQuota":{"usage":"42"}}')})
		end}
	end,
	run = function(c)
		local about = c.getAbout()
		assert(about.user.emailAddress == "reader@example.com" and about.storageQuota.usage == "42")
		assert(type(c.downloadFile) == "function" and c.uploadFile == nil)
	end,
}
