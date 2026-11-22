-- Execute generated reference calls, checking options, nesting and streamed file behavior.
return {
	scenario = {publisher = {client_id = "fixture-app-key", client_secret = "fixture-private-secret"}, auth_method = "oauth", auth_config = {}},
	access = {files = "write", sharing = "write", file_requests = "write"},
	configure = function()
		requests = {}
		responses = {}
		fs = fixture.files()
		http = {request = function(request)
			table.insert(requests, request)
			local response = table.remove(responses, 1)
			assert(response, "unexpected request")
			return fixture.operation({statusCode = 200, headers = response.headers or {}, body = fixture.reader(response.body)})
		end}
	end,
	run = function()
		responses = {{body = '{"entries":[{".tag":"file","name":"report.pdf","path_lower":"/reports/report.pdf"}],"cursor":"next-page","has_more":true}'}}
		local page = fixture.example("listFolder")
		assert(page.entries[1].name == "report.pdf" and page.has_more and page.cursor == "next-page")
		local request = requests[#requests]
		local args = json.decode(request.body)
		assert(request.url == "https://api.dropboxapi.com/2/files/list_folder" and args.path == "/Reports" and args.limit == 100 and args.recursive == false)

		responses = {{body = '{"metadata":{".tag":"folder","name":"New folder"}}'}}
		assert(fixture.example("createFolder").metadata.name == "New folder")
		request = requests[#requests]
		assert(request.url == "https://api.dropboxapi.com/2/files/create_folder_v2" and json.decode(request.body).path == "/Reports/New folder")

		local file = fs.open("upload.txt", "w")
		file:write("quarterly report")
		await(file:close())
		responses = {{body = '{".tag":"file","name":"upload.txt","id":"id:upload","size":16}'}}
		assert(fixture.example("upload").id == "id:upload")
		request = requests[#requests]
		args = json.decode(request.headers["Dropbox-API-Arg"][1])
		assert(request.url == "https://content.dropboxapi.com/2/files/upload" and args.path == "/Reports/upload.txt" and args.mode == "add" and args.session_path == nil)
		assert(await(request.body:readAll()) == "quarterly report")
		await(request.body:close())

		responses = {{headers = {["dropbox-api-result"] = {'{".tag":"file","name":"report.pdf"}'}}, body = "PDF bytes"}}
		local downloaded = fixture.example("download")
		assert(downloaded.session_path == "downloads/report.pdf" and downloaded.size == 9 and downloaded.result.name == "report.pdf")
		assert(downloaded.url == "https://houston.test/downloads/report.pdf")

		responses = {{body = '{"matches":[],"has_more":false}'}}
		assert(#fixture.example("search").matches == 0)
		args = json.decode(requests[#requests].body)
		assert(args.query == "report" and args.options.path == "/Reports" and args.options.max_results == 20)

		responses = {{body = "null"}}
		assert(fixture.example("addFolderMember").success)
		args = json.decode(requests[#requests].body)
		assert(args.shared_folder_id == "84528192421" and args.quiet == true)
		assert(args.members[1].member[".tag"] == "email" and args.members[1].member.email == "ada@example.com" and args.members[1].access_level == "viewer")

		responses = {{body = '{".tag":"file","id":"id:report","name":"report.pdf","size":9}'}}
		local stat = fixture.example("statFile")
		assert(stat.id == "id:report" and stat.size == 9 and not stat.isFolder)
		assert(json.decode(requests[#requests].body).path == "/Reports/report.pdf")

		responses = {{body = '{"account_id":"dbid:account","email":"ada@example.com"}'}}
		assert(fixture.example("getCurrentAccount").email == "ada@example.com")
		assert(requests[#requests].body == nil, "zero-argument example must preserve the void RPC body")

		responses = {{body = '{"id":"oaCAVmEyrqYnkZX9955Y","is_open":false}'}}
		assert(fixture.example("updateFileRequest").is_open == false)
		assert(json.decode(requests[#requests].body).open == false)
		assert(#responses == 0)
	end,
}
