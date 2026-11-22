-- Session files post as multipart payload_json plus files[n], within the server's per-file upload limit.
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret", bot_token = "fixture-bot-token"},
		config = {}, auth_method = "oauth", auth_config = {}, granted_scopes = {"bot"}, facts = {guild_id = "290926798626357999"}},
	access = {data = "write"},
	configure = function()
		fs = fixture.files()
		requests, responses, forms = {}, {}, {}
		http = {request = function(req)
			table.insert(requests, req)
			if req.body ~= nil then
				local contentType = req.headers["Content-Type"][1]
				assert(type(req.body) ~= "string", "the upload was buffered instead of streamed")
				local boundary = string.match(contentType, "^multipart/form%-data; boundary=(.+)$")
				assert(boundary, "attachments are sent as multipart/form-data, not " .. contentType)
				if skipBody then
					req.body:close()
				else
					table.insert(forms, {boundary = boundary, raw = await(req.body:readAll())})
				end
			end
			assert(#responses > 0, "unexpected request: " .. req.url)
			local response = table.remove(responses, 1)
			if type(response) == "string" then response = {body = response} end
			return fixture.operation({statusCode = response.status or 200, headers = {}, body = fixture.reader(response.body or "")})
		end}
		API = "https://discord.com/api/v10/"
		G, C, M = "290926798626357999", "1300000000000000001", "1400000000000000001"
		CHANNEL = '{"id":"' .. C .. '","type":0,"guild_id":"' .. G .. '","name":"general"}'
		function server(tier) return '{"id":"' .. G .. '","name":"Fixture","premium_tier":' .. tier .. '}' end
		POSTED = '{"id":"1400000000000000009","channel_id":"' .. C .. '","content":"Contract drafts","attachments":'
			.. '[{"id":"1500000000000000001","filename":"Contract (EN).pdf","size":17,"content_type":"application/pdf",'
			.. '"url":"https://cdn.discordapp.com/attachments/1/2/Contract_EN.pdf"}]}'
		function write(path, ...)
			local file = fs.open(path, "w")
			for _, chunk in {...} do await(file:write(chunk)) end
			await(file:close())
		end
		-- The checked channel, then the server's boost level, then the upload.
		function uploaded(first)
			for index, path in {"channels/" .. C, "guilds/" .. G} do
				local req = requests[first + index - 1]
				assert(req.method == "GET" and req.url == API .. path, "expected GET " .. path .. " before the upload")
			end
			local req = requests[first + 2]
			assert(req.method == "POST" and req.url == API .. "channels/" .. C .. "/messages")
			assert(req.headers["User-Agent"][1] == "DiscordBot (https://ok-houston.com, 1.0)" and req.headers.Authorization == nil)
			local form = table.remove(forms, 1)
			local raw, delimiter = "\r\n" .. form.raw, "\r\n--" .. form.boundary
			assert(string.sub(raw, 1, #delimiter + 2) == delimiter .. "\r\n" and string.sub(raw, -#delimiter - 4) == delimiter .. "--\r\n")
			local parts, position = {}, #delimiter + 3
			while true do
				local boundary = string.find(raw, delimiter, position, true)
				table.insert(parts, string.sub(raw, position, boundary - 1))
				position = boundary + #delimiter + 2
				if string.sub(raw, position - 2, position - 1) == "--" then break end
			end
			local payload = string.match(parts[1], '^Content%-Disposition: form%-data; name="payload_json"\r\nContent%-Type: application/json\r\n\r\n(.*)$')
			assert(payload, "payload_json comes first: " .. parts[1])
			local files = {}
			for index = 2, #parts do
				local name, filename, data = string.match(parts[index], '^Content%-Disposition: form%-data; name="(files%[%d+%])"; filename="(.-)"\r\n\r\n(.*)$')
				assert(name == "files[" .. index - 2 .. "]", "unexpected part " .. parts[index])
				files[index - 1] = {filename = filename, data = data}
			end
			return json.decode(payload), files
		end
		function rejected(fn, ...)
			local before = #requests
			local ok, err = pcall(fn, ...)
			assert(not ok and #requests == before, "invalid input reached Discord")
			return tostring(err)
		end
	end,
	run = function(discord)
		write("outputs/contract.pdf", "%PDF-1.7 contract")
		write("outputs/contrat.pdf", "%PDF-1.7 contrat\r\n--fake-boundary\r\n")

		responses = {CHANNEL, server(0), POSTED}
		local files = {{path = "outputs/contract.pdf", filename = "Contract (EN).pdf", description = "English draft"}, "outputs/contrat.pdf"}
		local posted = discord.postMessage(C, "Contract drafts", {files = files})
		assert(posted.attachments[1].filename == "Contract (EN).pdf" and posted.attachments[1].size == 17, "the posted message keeps its attachments")
		local body, sent = uploaded(1)
		assert(body.content == "Contract drafts" and body.files == nil and json.encode(body.allowed_mentions.parse) == "[]")
		assert(#body.attachments == 2 and body.attachments[1].id == 0 and body.attachments[1].filename == "Contract (EN).pdf"
			and body.attachments[1].description == "English draft", "attachments[0] describes files[0]")
		assert(body.attachments[2].id == 1 and body.attachments[2].filename == "contrat.pdf" and body.attachments[2].description == nil,
			"a bare path is named after its last segment")
		assert(#sent == 2 and sent[1].filename == "Contract (EN).pdf" and sent[1].data == "%PDF-1.7 contract")
		assert(sent[2].filename == "contrat.pdf" and sent[2].data == "%PDF-1.7 contrat\r\n--fake-boundary\r\n", "file bytes are sent unchanged")
		assert(type(files[2]) == "string" and files[1].size == nil, "options are not mutated")

		responses = {CHANNEL, server(1), POSTED}
		discord.reply(C, M, "", {files = "outputs/contract.pdf", allowed_mentions = {replied_user = true}})
		body, sent = uploaded(4)
		assert(body.content == nil and body.message_reference.message_id == M and body.allowed_mentions.replied_user == true,
			"a reply can carry only files")
		assert(#sent == 1 and sent[1].filename == "contract.pdf")

		local block = string.rep("a", 1024 * 1024)
		local big = fs.open("big.bin", "w")
		for _ = 1, 50 do await(big:write(block)) end
		await(big:write("a"))
		await(big:close())
		for tier, limit in {[1] = 20, [2] = 50} do
			responses = {CHANNEL, server(tier)}
			local before = #requests
			local ok, err = pcall(discord.postMessage, C, "Big", {files = {"outputs/contract.pdf", "big.bin"}})
			assert(not ok and string.find(tostring(err), "big.bin is 50.1 MiB; this server accepts files up to " .. limit .. " MiB each", 1, true), tostring(err))
			assert(#requests == before + 2 and #responses == 0, "an oversized file is refused before anything is uploaded")
		end
		skipBody = true
		responses = {CHANNEL, server(3), POSTED}
		discord.postMessage(C, nil, {files = {"big.bin"}})
		assert(#requests == 13 and requests[13].method == "POST", "boost level 3 accepts files over 50 MiB")
		skipBody = false
		assert(string.find(rejected(discord.postMessage, C, "Big", {files = table.create(5, "big.bin")}), "more than 250 MiB", 1, true),
			"files over Houston's total upload limit are refused before any request")

		responses = {'{"id":"' .. C .. '","type":0,"guild_id":"390926798626357000"}'}
		local ok = pcall(discord.postMessage, C, "Hi", {files = {"outputs/contract.pdf"}})
		assert(not ok and #requests == 14 and #responses == 0, "another server's channel is refused before the upload")

		write("folder/inside.txt", "x")
		rejected(discord.postMessage, C, "", {})
		rejected(discord.postMessage, C, "Hi", {files = {}})
		rejected(discord.postMessage, C, "Hi", {files = table.create(11, "outputs/contract.pdf")})
		rejected(discord.postMessage, C, "Hi", {files = {path = "outputs/contract.pdf"}})
		assert(string.find(rejected(discord.postMessage, C, "Hi", {files = {"missing.pdf"}}), "missing.pdf is not a session file", 1, true))
		rejected(discord.postMessage, C, "Hi", {files = {"folder"}})
		rejected(discord.postMessage, C, "Hi", {files = {"outputs/"}})
		rejected(discord.postMessage, C, "Hi", {files = {{path = "outputs/contract.pdf", filename = "a/b.pdf"}}})
		rejected(discord.postMessage, C, "Hi", {files = {{path = "outputs/contract.pdf", filename = "a\nb.pdf"}}})
		rejected(discord.postMessage, C, "Hi", {files = {{path = "outputs/contract.pdf", description = string.rep("x", 1025)}}})
		assert(string.find(rejected(discord.postMessage, C, "Hi", {files = {{path = "outputs/contract.pdf", spoiler = true}}}),
			"use path, filename or description", 1, true))
		rejected(discord.postMessage, C, 42, {files = {"outputs/contract.pdf"}})
		rejected(discord.editMessage, C, M, "Edited", {files = {"outputs/contract.pdf"}})
	end,
}
