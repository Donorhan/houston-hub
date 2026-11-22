-- Execute every documented call against the real connector; output schemas are checked by fixture.example.
return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {messages = "organize", drafts = "manage", sending = "send"},
	configure = function()
		fs = fixture.files()
		requests, responses = {}, {}
		http = {request = function(req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			local expected = table.remove(responses, 1)
			assert(req.method == expected.method, req.method)
			assert(req.url == expected.url, req.url)
			if expected.body then assert(req.body == expected.body, req.body) end
			if expected.compose then
				assert(string.find(req.body, "To: ana@example.com\r\n", 1, true))
				assert(string.find(req.body, "Subject: Launch plan\r\n", 1, true))
				assert(string.find(req.body, base64.encode("Please review the launch plan."), 1, true))
			end
			table.insert(requests, req)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(expected.response)})
		end}
	end,
	run = function(c)
		local API = "https://gmail.googleapis.com/gmail/v1/users/me"
		local function expect(method, path, response, body)
			table.insert(responses, {method = method, url = API .. path, response = response, body = body})
		end
		expect("GET", "/labels", '{"labels":[{"id":"INBOX","name":"INBOX","type":"system"}]}')
		assert(fixture.example("listLabels").labels[1].id == "INBOX")
		expect("GET", "/labels/INBOX", '{"id":"INBOX","name":"INBOX","messagesUnread":3}')
		assert(fixture.example("getLabel").messagesUnread == 3)
		expect("GET", "/messages?q=is%3Aunread%20in%3Ainbox&maxResults=20", '{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"next","resultSizeEstimate":2}')
		assert(fixture.example("listMessages").nextPageToken == "next")
		expect("GET", "/threads?q=from%3Aana%40example.com&maxResults=20", '{"threads":[{"id":"t1","snippet":"Plan","historyId":"12345"}]}')
		assert(fixture.example("listThreads").threads[1].id == "t1")
		expect("GET", "/drafts?maxResults=20", '{"drafts":[{"id":"d1","message":{"id":"m1","threadId":"t1"}}]}')
		assert(fixture.example("listDrafts").drafts[1].id == "d1")
		expect("GET", "/history?startHistoryId=12345&maxResults=20", '{"history":[{"id":"12346","messagesAdded":[{"message":{"id":"m1","threadId":"t1"}}]}],"historyId":"12346"}')
		assert(fixture.example("listHistory").historyId == "12346")
		expect("POST", "/messages/m1/modify", '{"id":"m1","threadId":"t1","labelIds":["INBOX"]}', '{"removeLabelIds":["UNREAD"]}')
		assert(fixture.example("modifyMessage").labelIds[1] == "INBOX")
		expect("POST", "/messages/batchModify", "")
		assert(fixture.example("batchModifyMessages").success)
		local batch = json.decode(requests[#requests].body)
		assert(#batch.ids == 2 and batch.ids[2] == "m2" and batch.removeLabelIds[1] == "UNREAD")
		expect("POST", "/threads/t1/modify", '{"id":"t1","messages":[{"id":"m1"}]}', '{"removeLabelIds":["INBOX"]}')
		assert(fixture.example("modifyThread").id == "t1")
		expect("POST", "/labels", '{"id":"Label_1","name":"Projects/Launch"}', '{"name":"Projects/Launch"}')
		assert(fixture.example("createLabel").name == "Projects/Launch")
		expect("PATCH", "/labels/Label_1", '{"id":"Label_1","name":"Projects/Launch"}', '{"name":"Projects/Launch"}')
		assert(fixture.example("updateLabel").name == "Projects/Launch")
		expect("DELETE", "/labels/Label_1", "")
		assert(fixture.example("deleteLabel").success)
		expect("DELETE", "/drafts/d1", "")
		assert(fixture.example("deleteDraft").success)

		local raw = {id = "m1", threadId = "t1", payload = {mimeType = "text/plain", headers = {{name = "Subject", value = "Plan"}}, body = {data = base64.encode("Please review.", {url = true, pad = false})}}}
		expect("GET", "/messages/m1?format=full", json.encode(raw))
		assert(fixture.example("getMessage").body == "Please review.")
		for _, id in {"m1", "m2"} do
			expect("GET", "/messages/" .. id .. "?format=metadata&metadataHeaders=From&metadataHeaders=Subject", json.encode({id = id, threadId = "t1", payload = {headers = {{name = "Subject", value = "Plan"}}}}))
		end
		local messages = fixture.example("getMessages")
		assert(#messages == 2 and messages[1].id == "m1" and messages[2].id == "m2" and messages[2].subject == "Plan")
		expect("GET", "/threads/t1?format=full", json.encode({id = "t1", historyId = "12345", messages = {raw}}))
		assert(fixture.example("getThread").messages[1].body == "Please review.")
		expect("GET", "/drafts/d1?format=full", json.encode({id = "d1", message = raw}))
		assert(fixture.example("getDraft").message.body == "Please review.")
		expect("GET", "/messages/m1/attachments/a1", json.encode({size = 6, data = base64.encode("report", {url = true, pad = false})}))
		local saved = fixture.example("getAttachment")
		assert(saved.path == "files/report.pdf" and saved.size == 6)
		local file = fs.open(saved.path, "r")
		assert(await(file:readAll()) == "report")
		await(file:close())
		expect("GET", "/labels", '{"labels":[{"id":"Label_1","name":"Projects"},{"id":"INBOX","name":"INBOX"}]}')
		assert(fixture.example("listMailFolders")[1].id == "INBOX")

		for _, spec in {{"sendMessage", "POST", "/messages/send", '{"id":"m2","threadId":"t2","labelIds":["SENT"]}'},
			{"createDraft", "POST", "/drafts", '{"id":"d1","message":{"id":"m1","threadId":"t1"}}'},
			{"updateDraft", "PUT", "/drafts/d1", '{"id":"d1","message":{"id":"m1","threadId":"t1"}}'}} do
			table.insert(responses, {method = spec[2], url = "https://gmail.googleapis.com/upload/gmail/v1/users/me" .. spec[3] .. "?uploadType=multipart", response = spec[4], compose = true})
			assert(fixture.example(spec[1]).id == (if spec[1] == "sendMessage" then "m2" else "d1"))
		end
		assert(#responses == 0 and #requests == 23)
		local count = 0
		for _ in c do count += 1 end
		assert(count == 22, "execute an example for every configured operation")
	end,
}
