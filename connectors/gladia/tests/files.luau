-- Native file and Reader ownership, including media larger than the JSON result limit.
return {
	scenario = {config = {access = "read-write"}, auth_method = "api_key", auth_config = {token = "gladia-fixture-key"}},
	configure = function()
		fs = fixture.files()
		opened = {}
		local open = fs.open
		fs.open = function(path, mode)
			local file = open(path, mode)
			if mode == "r" then table.insert(opened, file) end
			return file
		end
		requests = 0
		admissionFailure = false
		transportTimeout = false
		responseStatus = 200
		responseBody = nil
		http = {request = function(req)
			requests += 1
			if admissionFailure then
				rejectedBody = req.body
				error("HTTP admission failed")
			end
			if transportTimeout then error({code = "timeout", message = "request timed out"}) end
			if req.body ~= nil then
				assert(req.method == "POST" and req.url == "https://api.gladia.io/v2/upload")
				assert(type(req.body) ~= "string", "upload buffered the audio")
				uploadContentType = req.headers["Content-Type"][1]
				local received = open("received.multipart", "w")
				received:write(req.body)
				await(received:close())
			end
			return fixture.operation({statusCode = responseStatus, headers = {}, body = responseBody or fixture.reader('{"audio_url":"https://api.gladia.io/file/audio-1"}')})
		end}
	end,
	run = function(c)
		local id = "45463597-20b7-4af7-b3b3-f5fb778203ab"
		local block = string.rep("a", 1024 * 1024)
		local size = 8 * #block + 17
		local input = fs.open("large.wav", "w")
		for _ = 1, 8 do await(input:write(block)) end
		await(input:write(string.rep("a", 17)))
		await(input:close())
		assert(c.uploadAudio({path = "large.wav"}).audio_url == "https://api.gladia.io/file/audio-1")
		local sentSize = await(fs.stat("received.multipart")).size
		assert(sentSize > size and sentSize < size + 1024, "multipart lost audio bytes")
		assert(not pcall(function() await(opened[#opened]:read(1)) end), "upload left its input file open")
		local received = fs.open("received.multipart", "r")
		local prefix = await(received:read(1024)).data
		assert(string.find(prefix, 'name="audio"; filename="large.wav"', 1, true))
		assert(string.find(prefix, "Content-Type: audio/wav", 1, true))
		local boundary = string.match(uploadContentType, "boundary=(.+)$")
		assert(boundary and string.sub(prefix, 1, #boundary + 4) == "--" .. boundary .. "\r\n")
		local _, headerEnd = string.find(prefix, "\r\n\r\n", 1, true)
		assert(headerEnd)
		await(received:seek(headerEnd, "start"))
		local remaining = size
		while remaining > 0 do
			local chunk = await(received:read(math.min(remaining, #block)))
			assert(not chunk.done and chunk.data == string.rep("a", #chunk.data), "multipart changed audio bytes")
			remaining -= #chunk.data
		end
		assert(await(received:readAll()) == "\r\n--" .. boundary .. "--\r\n", "multipart trailer disagrees with its Content-Type")
		await(received:close())

		local invalid = fs.open("invalid\nname.wav", "w")
		invalid:write("audio")
		await(invalid:close())
		local before = requests
		local ok, err = pcall(c.uploadAudio, {path = "invalid\nname.wav"})
		assert(not ok and requests == before, "invalid multipart filename reached HTTP")
		assert(not pcall(function() await(opened[#opened]:read(1)) end), "multipart construction left the audio file open")

		-- A refused request must release both the multipart Reader and its owned File.
		admissionFailure = true
		before = requests
		ok, err = pcall(c.uploadAudio, {path = "large.wav"})
		assert(not ok and string.find(tostring(err), "HTTP admission failed", 1, true), tostring(err))
		assert(requests == before + 1, "upload failure was replayed")
		assert(not pcall(function() await(opened[#opened]:read(1)) end), "HTTP admission left the audio file open")
		assert(not pcall(function() await(rejectedBody:readAll()) end), "HTTP admission left the multipart Reader open")
		admissionFailure = false
		transportTimeout = true
		before = requests
		ok, err = pcall(c.createTranscription, {audio_url = "https://example.com/audio.wav"})
		assert(not ok and string.find(tostring(err), "list transcriptions before creating another", 1, true), tostring(err))
		assert(string.find(tostring(err), '"retryable":true', 1, true), tostring(err))
		assert(requests == before + 1, "timed-out creation was replayed")
		transportTimeout = false

		-- Download streams beyond the string limit, preserving every byte.
		responseBody = fixture.reader(string.rep("d", size))
		local saved = c.downloadAudio({id = id, path = "download.wav"})
		assert(saved.size == size and saved.path == "download.wav" and type(saved.url) == "string")
		local downloaded = fs.open("download.wav", "r")
		local total = 0
		while true do
			local chunk = await(downloaded:read(1024 * 1024))
			if chunk.done then break end
			assert(chunk.data == string.rep("d", #chunk.data))
			total += #chunk.data
		end
		await(downloaded:close())
		assert(total == size)

		-- A failed replacement preserves the old file, even after partial incoming bytes.
		local original = fs.open("keep.wav", "w")
		original:write("original audio")
		await(original:close())
		responseBody = stream.concat({"partial replacement", gzip.decode(fixture.reader("not gzip"))})
		ok = pcall(c.downloadAudio, {id = id, path = "keep.wav"})
		assert(not ok, "broken audio stream returned success")
		local preserved = fs.open("keep.wav", "r")
		assert(await(preserved:readAll()) == "original audio")
		await(preserved:close())

		responseStatus, responseBody = 403, fixture.reader('{"message":"Audio access denied"}')
		ok, err = pcall(c.downloadAudio, {id = id, path = "keep.wav"})
		assert(not ok and string.find(tostring(err), "Gladia HTTP 403: Audio access denied", 1, true), tostring(err))
		assert(not string.find(tostring(err), "neither queued nor processing", 1, true), "download error used deletion advice")
		preserved = fs.open("keep.wav", "r")
		assert(await(preserved:readAll()) == "original audio")
		await(preserved:close())
	end,
}
