return {
	-- Files stays at Read: folder limits apply, and a read-write folder still gets no writes.
	scenario = {publisher = {client_id = "fixture-app-key", client_secret = "fixture-private-secret"}, auth_method = "oauth", auth_config = {}},
	config = {folder_policy = true, path_access = '{"/Reports":"read-only","/Incoming":"read-write"}'},
	configure = function()
		http = {request = function(req)
			assert(req.url == "https://api.dropboxapi.com/2/files/get_metadata")
			local path = string.lower(json.decode(req.body).path)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(json.encode({[".tag"] = "folder", path_lower = path, name = "folder", id = "id:" .. path}))})
		end}
	end,
	run = function(c)
		for _, name in {"upload", "createFolder", "move", "copy", "delete", "restore", "getCurrentAccount", "listSharedLinks", "listFileRequests"} do assert(c[name] == nil, "Read folder limits expose " .. name) end
		assert(type(c.listFolder) == "function" and type(c.download) == "function", "Read folder limits lack reads")
		assert(c.getMetadata({path = "/Incoming"}).path_lower == "/incoming", "Read folder limits denied a configured folder")
		assert(not pcall(c.getMetadata, {path = "/Outside"}), "Read folder limits reached an unlisted folder")
	end,
}
