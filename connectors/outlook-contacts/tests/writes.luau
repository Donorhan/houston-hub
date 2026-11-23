return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "write"},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			assert(req.headers == nil or req.headers.Authorization == nil, "the proxy injects Authorization")
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "")})
		end}
	end,
	run = function(c)
		local API = "https://graph.microsoft.com/v1.0/me"
		local function last() return requests[#requests] end
		local function body() return json.decode(last().body) end
		local function fails(expected: {string}, fn: (...any) -> any, ...: any)
			local ok, err = pcall(fn, ...)
			assert(not ok, "call succeeded")
			for _, text in expected do assert(string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err)) end
		end

		-- Contacts: the body carries Graph's fields; folderId and id only shape the path.
		responses = {{status = 201, body = '{"id":"C1","displayName":"Ana Silva"}'}, {status = 201, body = '{"id":"C2"}'}, {body = '{"id":"C1","jobTitle":"CTO"}'}, {body = '{"id":"C2"}'}, {status = 204}, {status = 204}}
		local address = {street = "1 Main St", city = "Redmond", state = "WA", countryOrRegion = "United States", postalCode = "98052"}
		assert(c.contacts.create({givenName = "Ana", surname = "Silva", emailAddresses = {{address = "ana@example.com", name = "Ana Silva"}}, homeAddress = address}).id == "C1")
		local sent = body()
		assert(last().method == "POST" and last().url == API .. "/contacts" and last().headers["Content-Type"][1] == "application/json", last().url)
		assert(sent.givenName == "Ana" and sent.emailAddresses[1].address == "ana@example.com" and sent.homeAddress.postalCode == "98052" and sent.folderId == nil, last().body)
		c.contacts.create({folderId = "AQMk-F1==", displayName = "Bo Chen", businessPhones = {"+1 425 555 0100"}})
		assert(last().url == API .. "/contactFolders/AQMk-F1%3D%3D/contacts" and last().body == '{"businessPhones":["+1 425 555 0100"],"displayName":"Bo Chen"}', last().body)
		assert(c.contacts.update({id = "C1", jobTitle = "CTO", categories = {}}).jobTitle == "CTO")
		assert(last().method == "PATCH" and last().url == API .. "/contacts/C1" and last().body == '{"categories":[],"jobTitle":"CTO"}', last().body)
		c.contacts.update({id = "C2", folderId = "F1", mobilePhone = "+33 6 12 34 56 78", birthday = json.decode("null")})
		assert(last().url == API .. "/contactFolders/F1/contacts/C2" and last().body == '{"birthday":null,"mobilePhone":"+33 6 12 34 56 78"}', last().body)
		assert(c.contacts.delete({id = "C1"}).success and last().method == "DELETE" and last().url == API .. "/contacts/C1" and last().body == nil, last().url)
		c.contacts.delete({id = "C2", folderId = "F1"})
		assert(last().url == API .. "/contactFolders/F1/contacts/C2", last().url)

		-- Folders: created in the default folder or inside another, renamed, moved and deleted.
		responses = {{status = 201, body = '{"id":"F1","displayName":"Suppliers"}'}, {status = 201, body = '{"id":"F2"}'}, {body = '{"id":"F1"}'}, {body = '{"id":"F2"}'}, {status = 204}}
		assert(c.folders.create({displayName = "Suppliers"}).id == "F1" and last().url == API .. "/contactFolders" and last().body == '{"displayName":"Suppliers"}', last().body)
		c.folders.create({displayName = "Paris", parentFolderId = "F1"})
		assert(last().method == "POST" and last().url == API .. "/contactFolders/F1/childFolders" and last().body == '{"displayName":"Paris"}', last().body)
		c.folders.update({folderId = "F1", displayName = "Key suppliers"})
		assert(last().method == "PATCH" and last().url == API .. "/contactFolders/F1" and last().body == '{"displayName":"Key suppliers"}', last().body)
		c.folders.update({folderId = "F2", parentFolderId = "F0"})
		assert(last().url == API .. "/contactFolders/F2" and last().body == '{"parentFolderId":"F0"}', last().body)
		assert(c.folders.delete({folderId = "F2"}).success and last().method == "DELETE" and last().url == API .. "/contactFolders/F2", last().url)

		-- Write bodies are closed and typed; invalid input never reaches the network.
		local before = #requests
		fails({"contacts.create requires contact fields"}, c.contacts.create, {folderId = "F1"})
		fails({"contacts.create received an unknown option email"}, c.contacts.create, {givenName = "Ana", email = "ana@example.com"})
		fails({"emailAddresses must be an array"}, c.contacts.create, {emailAddresses = "ana@example.com"})
		fails({"mobilePhone must be a string"}, c.contacts.create, {mobilePhone = 33612345678})
		fails({"homeAddress must be an object"}, c.contacts.create, {homeAddress = "1 Main St"})
		fails({"contacts.update requires fields to change"}, c.contacts.update, {id = "C1"})
		fails({"contacts.update received an unknown option parentFolderId"}, c.contacts.update, {id = "C1", parentFolderId = "F1"})
		fails({"id must be a nonempty string"}, c.contacts.update, {jobTitle = "CTO"})
		fails({"contacts.delete received an unknown option force"}, c.contacts.delete, {id = "C1", force = true})
		fails({"displayName must be a nonempty string"}, c.folders.create, {})
		fails({"folders.create received an unknown option color"}, c.folders.create, {displayName = "X", color = "red"})
		fails({"folders.update requires displayName or parentFolderId"}, c.folders.update, {folderId = "F1"})
		fails({"displayName must be a nonempty string"}, c.folders.update, {folderId = "F1", displayName = ""})
		fails({"folderId must be a nonempty string"}, c.folders.delete, {})
		fails({"parentFolderId must be a nonempty string"}, c.folders.update, {folderId = "F1", parentFolderId = ""})
		fails({"jobTitle must be a string"}, c.contacts.update, {id = "C1", jobTitle = true})
		fails({"emailAddresses[1] received an unknown field email"}, c.contacts.create, {emailAddresses = {{email = "ana@example.com"}}})
		fails({"emailAddresses[1].address is required"}, c.contacts.create, {emailAddresses = {{name = "Ana"}}})
		fails({"emailAddresses[1].address must be a nonempty string"}, c.contacts.create, {emailAddresses = {{address = json.decode("null")}}})
		fails({"homeAddress received an unknown field zip"}, c.contacts.create, {homeAddress = {zip = "75001"}})
		fails({"businessPhones[2] must be a string"}, c.contacts.create, {businessPhones = {"+1 425 555 0100", 4255550101}})
		fails({"categories must be an array"}, c.contacts.update, {id = "C1", categories = {first = "VIP"}})
		fails({"businessPhones must be an array"}, c.contacts.create, {businessPhones = {[1] = "+1 425 555 0100", [3] = "+1 425 555 0101"}})
		assert(#requests == before, "invalid writes reached Graph")

		-- A refused write keeps Graph's reason; a server error on a write may still have been applied.
		-- Microsoft Q&A reports, reproduced by Microsoft staff, show folder deletes refused with 403 ErrorCannotDeleteObject.
		responses = {
			{status = 403, body = '{"error":{"code":"ErrorCannotDeleteObject","message":"Object cannot be deleted."}}'},
			{status = 409, body = '{"error":{"code":"ErrorFolderExists","message":"A folder with the specified name already exists."}}'},
			{status = 503, headers = {["retry-after"] = {"30"}}, body = '{"error":{"code":"ServiceUnavailable","message":"Try later"}}'},
			{status = 429, headers = {["retry-after"] = {"5"}}, body = '{"error":{"code":"ApplicationThrottled","message":"Slow down"}}'},
		}
		fails({"HTTP 403 (ErrorCannotDeleteObject)", "Object cannot be deleted", '"retryable":false'}, c.folders.delete, {folderId = "F0"})
		fails({"HTTP 409 (ErrorFolderExists)", '"retryable":false'}, c.folders.create, {displayName = "Suppliers"})
		fails({"HTTP 503 (ServiceUnavailable)", "Retry-After: 30", '"retryable":false'}, c.contacts.create, {givenName = "Ana"})
		-- Graph refuses a throttled write before acting, so repeating it is safe.
		fails({"HTTP 429 (ApplicationThrottled)", "Retry-After: 5", '"retryable":true'}, c.contacts.update, {id = "C1", jobTitle = "CTO"})
		assert(#requests == before + 4 and #responses == 0)
	end,
}
