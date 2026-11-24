return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "write"},
	configure = function()
		requests, responses = {}, {}
		fs = fixture.files()
		http = {request = function(req)
			assert(req.headers == nil or req.headers.Authorization == nil, "the proxy injects Authorization")
			table.insert(requests, req)
			if req.body ~= nil and type(req.body) ~= "string" then req.body = await(req.body:readAll()) end
			assert(#responses > 0, "unexpected request: " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "")})
		end}
	end,
	run = function(c)
		local GRAPH = "https://graph.microsoft.com/v1.0"
		local SITE_ID = "contoso.sharepoint.com,2c3f5e86,712a596e"
		local SITE = GRAPH .. "/sites/contoso.sharepoint.com%2C2c3f5e86%2C712a596e"
		local DRIVE = GRAPH .. "/drives/b%21hl4"
		local function last() return requests[#requests] end

		local bytes = string.char(0, 255) .. "quarterly figures"
		local file = fs.open("uploads/plan.pdf", "w")
		file:write(bytes)
		await(file:close())

		-- New files go to a folder by name; an existing name gets a numbered copy unless told otherwise.
		responses = {{status = 201, body = '{"id":"up","@microsoft.graph.downloadUrl":"https://contoso.sharepoint.com/x"}'}, {status = 201, body = '{"id":"up2"}'}, {body = '{"id":"F1"}'}}
		local created = c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", contentType = "application/pdf"})
		assert(created.id == "up" and created["@microsoft.graph.downloadUrl"] == nil)
		assert(last().method == "PUT" and last().url == DRIVE .. "/root:/plan.pdf:/content?@microsoft.graph.conflictBehavior=rename", last().url)
		assert(last().body == bytes and last().headers["Content-Type"][1] == "application/pdf" and last().headers["User-Agent"][1] == "ISV|AIBakery|Houston/1.0")
		c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", parentId = "01ABC", name = "Q3 plan.pdf", conflictBehavior = "replace"})
		assert(last().url == DRIVE .. "/items/01ABC:/Q3%20plan.pdf:/content?@microsoft.graph.conflictBehavior=replace", last().url)
		c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", itemId = "F1"})
		assert(last().method == "PUT" and last().url == DRIVE .. "/items/F1/content", last().url)

		responses = {{status = 201, body = '{"id":"dir"}'}, {body = '{"id":"F1","name":"Renamed.pdf"}'}, {status = 202}, {status = 204}}
		c.files.createFolder({driveId = "b!hl4", name = "Reports", parentId = "01ABC"})
		local body = json.decode(last().body)
		assert(last().method == "POST" and last().url == DRIVE .. "/items/01ABC/children" and body.name == "Reports" and body["@microsoft.graph.conflictBehavior"] == "fail", last().url)
		assert(c.files.update({driveId = "b!hl4", itemId = "F1", name = "Renamed.pdf", parentReference = {id = "dir"}}).name == "Renamed.pdf")
		body = json.decode(last().body)
		assert(last().method == "PATCH" and last().url == DRIVE .. "/items/F1?$select=id%2Cname%2Csize%2Cfile%2Cfolder%2Cpackage%2CparentReference%2CcreatedDateTime%2ClastModifiedDateTime%2CwebUrl", last().url)
		assert(body.name == "Renamed.pdf" and body.parentReference.id == "dir" and body.driveId == nil and body.itemId == nil and body.select == nil)
		assert(c.files.copy({driveId = "b!hl4", itemId = "F1", parentReference = {driveId = "b!other", id = "dir2"}}).success)
		assert(last().url == DRIVE .. "/items/F1/copy" and json.decode(last().body).parentReference.driveId == "b!other")
		assert(c.files.delete({driveId = "b!hl4", itemId = "F1"}).success)
		assert(last().method == "DELETE" and last().url == DRIVE .. "/items/F1" and last().body == nil)

		-- List items take column values keyed by internal name.
		responses = {{status = 201, body = '{"id":"5","fields":{"Title":"Launch plan"}}'}, {body = '{"Status":"Done"}'}, {status = 204}}
		assert(c.lists.createItem({siteId = SITE_ID, listId = "L1", fields = {Title = "Launch plan", Status = "Planned"}}).id == "5")
		body = json.decode(last().body)
		assert(last().method == "POST" and last().url == SITE .. "/lists/L1/items" and body.fields.Title == "Launch plan" and body.fields.Status == "Planned", last().body)
		assert(c.lists.updateItem({siteId = SITE_ID, listId = "L1", itemId = "5", fields = {Status = "Done"}}).Status == "Done")
		assert(last().method == "PATCH" and last().url == SITE .. "/lists/L1/items/5/fields" and last().body == '{"Status":"Done"}', last().body)
		assert(c.lists.deleteItem({siteId = SITE_ID, listId = "L1", itemId = "5"}).success)
		assert(last().method == "DELETE" and last().url == SITE .. "/lists/L1/items/5")

		-- Invalid writes never reach Graph.
		local sent = #requests
		for _, call in {
			function() return c.files.upload({path = "uploads/plan.pdf"}) end,
			function() return c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", conflictBehavior = "overwrite"}) end,
			function() return c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", itemId = "F1", name = "x.pdf"}) end,
			function() return c.files.upload({driveId = "b!hl4", path = "uploads/plan.pdf", name = "a:b.pdf"}) end,
			function() return c.files.upload({driveId = "b!hl4", path = "uploads/missing.pdf"}) end,
			function() return c.files.createFolder({driveId = "b!hl4"}) end,
			function() return c.files.update({driveId = "b!hl4", itemId = "../root"}) end,
			function() return c.files.delete({itemId = "F1"}) end,
			function() return c.lists.createItem({siteId = SITE_ID, listId = "L1"}) end,
			function() return c.lists.createItem({siteId = SITE_ID, listId = "L1", fields = {}}) end,
			function() return c.lists.createItem({siteId = SITE_ID, listId = "L1", fields = {"Title"}}) end,
			function() return c.lists.updateItem({siteId = SITE_ID, listId = "L1", fields = {Status = "Done"}}) end,
			function() return c.lists.updateItem({siteId = SITE_ID, listId = "L1", itemId = "5", fields = {Status = "Done"}, extra = 1}) end,
			function() return c.lists.deleteItem({siteId = SITE_ID, listId = "L1", itemId = "5/../6"}) end,
		} do assert(not pcall(call)) end
		assert(#requests == sent, "invalid writes reached Graph")

		-- A failed write reports Graph's error without retrying.
		responses = {{status = 409, body = '{"error":{"code":"nameAlreadyExists","message":"Name already exists"}}'}}
		local ok, err = pcall(c.files.createFolder, {driveId = "b!hl4", name = "Reports"})
		assert(not ok and string.find(tostring(err), "Microsoft Graph HTTP 409 (nameAlreadyExists)", 1, true) and string.find(tostring(err), '"retryable":false', 1, true), tostring(err))
		responses = {{status = 503, body = '{"error":{"code":"serviceNotAvailable","message":"Try later"}}'}}
		ok, err = pcall(c.lists.updateItem, {siteId = SITE_ID, listId = "L1", itemId = "5", fields = {Status = "Done"}})
		assert(not ok and string.find(tostring(err), '"retryable":false', 1, true), "a write that failed with a server error may have been applied")
		assert(#responses == 0)
	end,
}
