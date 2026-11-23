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
		local W = "https://graph.microsoft.com/v1.0/me/drive/items/I1/workbook"
		local VALUES = "?$select=address%2CrowCount%2CcolumnCount%2Cvalues"
		local NULL = json.decode("null")
		local function last() return requests[#requests] end
		local function body() return json.decode(last().body) end
		local function fails(expected: {string}, fn: (...any) -> any, ...: any)
			local ok, err = pcall(fn, ...)
			assert(not ok, "call succeeded")
			for _, text in expected do assert(string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err)) end
		end

		-- A session's id travels as workbook-session-id on every call that names it.
		responses = {{status = 201, body = '{"id":"cluster=PAR1&session=15.S1","persistChanges":true}'}, {status = 201, body = '{"id":"s2","persistChanges":false}'}}
		local opened = c.workbooks.createSession({itemId = "I1"})
		assert(opened.id == "cluster=PAR1&session=15.S1" and last().method == "POST" and last().url == W .. "/createSession", last().url)
		assert(last().body == '{"persistChanges":true}' and last().headers["Content-Type"][1] == "application/json", last().body)
		c.workbooks.createSession({itemId = "I1", persistChanges = false})
		assert(last().body == '{"persistChanges":false}', last().body)

		-- Grids keep null cells, which leave a cell unchanged; formulas and formats go alongside.
		local grid = '{"address":"Sheet1!A1:B2","rowCount":2,"columnCount":2,"values":[["Item","Qty"],["Pear",4]]}'
		responses = {{body = grid}, {body = grid}, {body = grid}}
		assert(c.ranges.update({itemId = "I1", address = "Sheet1!A1:B2", values = {{"Item", NULL}, {"Pear", 4}}, sessionId = opened.id}).values[2][2] == 4)
		assert(last().method == "PATCH" and last().url == W .. "/worksheets/Sheet1/range(address='A1%3AB2')" .. VALUES, last().url)
		assert(last().headers["workbook-session-id"][1] == opened.id and last().body == '{"values":[["Item",null],["Pear",4]]}', last().body)
		c.ranges.update({itemId = "I1", worksheet = "Sheet1", address = "C2", formulas = {{"=B2*1.2"}}, numberFormat = {{"0.00"}}, select = "address,formulas"})
		local sent = body()
		assert(last().url == W .. "/worksheets/Sheet1/range(address='C2')?$select=address%2Cformulas" and sent.formulas[1][1] == "=B2*1.2" and sent.numberFormat[1][1] == "0.00", last().url)
		assert(last().headers["workbook-session-id"] == nil and sent.select == nil and sent.address == nil and sent.worksheet == nil)
		c.ranges.update({itemId = "I1", name = "Totals", values = {{10}}})
		assert(last().url == W .. "/names/Totals/range" .. VALUES and last().body == '{"values":[[10]]}', last().body)

		responses = {{status = 204}, {status = 204}, {status = 201, body = '{"index":5,"values":[["2026-11-10","Pear",4]]}'}, {status = 201, body = '{"index":6}'},
			{status = 201, body = '{"id":"2","name":"Table2"}'}, {status = 201, body = '{"id":"3"}'}, {body = '{"address":"Sheet1!A5:XFD7"}'}, {status = 204}}
		assert(c.ranges.clear({itemId = "I1", address = "Sheet1!A2:D9"}).success and last().url == W .. "/worksheets/Sheet1/range(address='A2%3AD9')/clear", last().url)
		assert(last().method == "POST" and last().body == '{"applyTo":"Contents"}', last().body)
		c.ranges.clear({itemId = "I1", name = "Totals", applyTo = "All"})
		assert(last().url == W .. "/names/Totals/range/clear" and last().body == '{"applyTo":"All"}', last().body)
		assert(c.tables.addRows({itemId = "I1", table = "Table 1", values = {{"2026-11-10", "Pear", 4}}, index = 0}).index == 5)
		sent = body()
		assert(last().url == W .. "/tables/Table%201/rows/add" and sent.index == 0 and sent.values[1][3] == 4 and sent.table == nil, last().url)
		c.tables.addRows({itemId = "I1", table = "Table1", values = {{1, 2, 3}}})
		assert(last().body == '{"values":[[1,2,3]]}', last().body)
		assert(c.tables.add({itemId = "I1", address = "A1:D20", worksheet = "O'Brien"}).name == "Table2" and last().url == W .. "/worksheets/O%27Brien/tables/add", last().url)
		sent = body()
		assert(sent.address == "A1:D20" and sent.hasHeaders == true and sent.worksheet == nil, last().body)
		c.tables.add({itemId = "I1", address = "'Q1 Sales'!A1:B5", hasHeaders = false})
		sent = body()
		assert(last().url == W .. "/worksheets/Q1%20Sales/tables/add" and sent.address == "A1:B5" and sent.hasHeaders == false, last().body)
		-- Inserting and deleting shift the neighbouring cells.
		assert(c.ranges.insert({itemId = "I1", address = "Sheet1!5:7", shift = "Down"}).address == "Sheet1!A5:XFD7")
		assert(last().url == W .. "/worksheets/Sheet1/range(address='5%3A7')/insert" and last().body == '{"shift":"Down"}', last().url)
		assert(c.ranges.delete({itemId = "I1", name = "Totals", shift = "Left"}).success and last().url == W .. "/names/Totals/range/delete", last().url)
		assert(last().method == "POST" and last().body == '{"shift":"Left"}', last().body)

		responses = {{status = 201, body = '{"id":"{S2}","name":"Archive"}'}, {status = 201, body = '{"id":"{S3}","name":"Sheet3"}'}, {body = '{"id":"{S2}","name":"Old"}'}, {status = 204}, {status = 204}}
		assert(c.worksheets.add({itemId = "I1", name = "Archive"}).name == "Archive" and last().url == W .. "/worksheets/add" and last().body == '{"name":"Archive"}', last().url)
		c.worksheets.add({itemId = "I1"})
		assert(last().body == "{}", last().body)
		c.worksheets.update({itemId = "I1", worksheet = "Archive", name = "Old", visibility = "Hidden"})
		sent = body()
		assert(last().method == "PATCH" and last().url == W .. "/worksheets/Archive" and sent.name == "Old" and sent.visibility == "Hidden" and sent.worksheet == nil, last().url)
		assert(c.worksheets.delete({itemId = "I1", worksheet = "{S2}"}).success and last().method == "DELETE" and last().url == W .. "/worksheets/%7BS2%7D" and last().body == nil, last().url)
		assert(c.workbooks.closeSession({itemId = "I1", sessionId = opened.id}).success and last().url == W .. "/closeSession", last().url)
		assert(last().headers["workbook-session-id"][1] == opened.id and last().body == "", tostring(last().body))

		-- A new workbook is an .xlsx package uploaded by path, never over an existing file; the result
		-- keeps the workbook's item fields, without the signed download link.
		local ME = "https://graph.microsoft.com/v1.0/me/drive"
		local item = '{"id":"N1","name":"Budget 2026.xlsx","size":1290,"webUrl":"https://contoso-my.sharepoint.com/x","file":{"mimeType":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},'
			.. '"parentReference":{"id":"P1"},"lastModifiedDateTime":"2026-11-11T10:00:00Z","createdBy":{"user":{"displayName":"Ada"}},"@microsoft.graph.downloadUrl":"https://signed.example/x"}'
		responses = {{status = 201, body = item}, {status = 201, body = item}}
		local created = c.workbooks.create({name = "Budget 2026.xlsx"})
		assert(last().method == "PUT" and last().url == ME .. "/root:/Budget%202026.xlsx:/content?@microsoft.graph.conflictBehavior=fail", last().url)
		assert(last().headers["Content-Type"][1] == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
		assert(created.id == "N1" and created.parentReference.id == "P1" and created.file.mimeType ~= nil and created.createdBy == nil and created["@microsoft.graph.downloadUrl"] == nil)
		local archive = await(zip.open(last().body))
		local parts = {}
		for _, entry in archive.entries do table.insert(parts, entry.name) end
		assert(table.concat(parts, ",") == "[Content_Types].xml,_rels/.rels,xl/workbook.xml,xl/_rels/workbook.xml.rels,xl/worksheets/sheet1.xml,xl/styles.xml", table.concat(parts, ","))
		assert(string.find(await(archive:open("xl/workbook.xml"):readAll()), '<sheet name="Sheet1" sheetId="1" r:id="rId1"/>', 1, true))
		archive:close()
		local first = last().body
		c.workbooks.create({name = "Q3 sales.XLSX", parentId = "P1!101"})
		assert(last().url == ME .. "/items/P1%21101:/Q3%20sales.XLSX:/content?@microsoft.graph.conflictBehavior=fail" and last().body == first, last().url)
		-- A success without the new item fails where it happened.
		responses = {{status = 201}}
		fails({"Microsoft Graph returned no item for the new workbook"}, c.workbooks.create, {name = "Budget 2026.xlsx"})

		-- Invalid input never reaches the network.
		local before = #requests
		fails({"name must end in .xlsx"}, c.workbooks.create, {name = "Budget.xls"})
		fails({"name must end in .xlsx"}, c.workbooks.create, {name = ".xlsx"})
		for _, bad in {"10:30 notes.xlsx", "Reports/Budget.xlsx", "Q3 <draft>.xlsx", "What?.xlsx", "100%.xlsx", " Budget.xlsx"} do
			fails({"name cannot start with a space or contain"}, c.workbooks.create, {name = bad})
		end
		assert(not pcall(c.workbooks.create, {name = "Budget.xlsx", parentId = "P1/../P2"}), "a parentId with a slash reached the network")
		fails({"workbooks.create received an unknown option conflictBehavior"}, c.workbooks.create, {name = "Budget.xlsx", conflictBehavior = "replace"})
		fails({"ranges.update requires values, formulas or numberFormat"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1"})
		fails({"values rows must all have the same, nonzero number of cells"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1:B2", values = {{1, 2}, {3}}})
		fails({"values must be rows of cells"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1:B1", values = {1, 2}})
		fails({"formulas must be an array of rows"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1", formulas = {{"=1"}, extra = {"=2"}}})
		fails({"table is only for reading"}, c.ranges.update, {itemId = "I1", table = "Table1", values = {{1}}})
		fails({"address or name is required"}, c.ranges.clear, {itemId = "I1", worksheet = "Sheet1"})
		fails({"tables.addRows requires values"}, c.tables.addRows, {itemId = "I1", table = "Table1"})
		fails({"address needs its worksheet"}, c.tables.add, {itemId = "I1", address = "A1:B2"})
		fails({"name the worksheet in address or in worksheet"}, c.tables.add, {itemId = "I1", address = "Sales!A1:B2", worksheet = "Sales"})
		fails({"worksheets.update requires name, position or visibility"}, c.worksheets.update, {itemId = "I1", worksheet = "Sheet1"})
		fails({"sessionId must be a nonempty string"}, c.workbooks.closeSession, {itemId = "I1"})
		fails({"sessionId must be a session id"}, c.worksheets.list, {itemId = "I1", sessionId = "s1\r\nX-Evil: 1"})
		fails({"worksheets.delete received an unknown option"}, c.worksheets.delete, {itemId = "I1", worksheet = "Sheet1", force = true})
		fails({"ranges.update received an unknown option rowHidden"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1", values = {{1}}, rowHidden = true})
		fails({"address or name is required"}, c.ranges.update, {itemId = "I1", worksheet = "Sheet1", values = {{1}}})
		fails({"applyTo must be one of Contents, Formats, All"}, c.ranges.clear, {itemId = "I1", address = "Sheet1!A1", applyTo = "Everything"})
		fails({"ranges.insert requires shift"}, c.ranges.insert, {itemId = "I1", address = "Sheet1!A1"})
		fails({"shift must be one of Up, Left"}, c.ranges.delete, {itemId = "I1", address = "Sheet1!A1", shift = "Down"})
		fails({"index must be an integer of at least 0"}, c.tables.addRows, {itemId = "I1", table = "Table1", values = {{1}}, index = -1})
		fails({"visibility must be one of Visible, Hidden, VeryHidden"}, c.worksheets.update, {itemId = "I1", worksheet = "Sheet1", visibility = "Gone"})
		fails({"persistChanges must be a boolean"}, c.workbooks.createSession, {itemId = "I1", persistChanges = "yes"})
		fails({"worksheets.add received an unknown option tabColor"}, c.worksheets.add, {itemId = "I1", tabColor = "red"})
		fails({"name must be a nonempty string"}, c.worksheets.add, {itemId = "I1", name = ""})
		fails({"values cells must be strings, numbers, booleans or null"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1", values = {{{a = 1}}}})
		fails({"values cells must be strings, numbers, booleans or null"}, c.tables.addRows, {itemId = "I1", table = "Table1", values = {{1, 2, x = 3} :: {any}}})
		fails({"numberFormat cells must be strings or null"}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1", numberFormat = {{0}}})
		fails({"index must be an integer of at least 0"}, c.tables.addRows, {itemId = "I1", table = "Table1", values = {{1}}, index = 2 ^ 53})
		assert(#requests == before, "invalid input reached the network")

		-- A refused write keeps Graph's reason; an expired session and a timeout read as such.
		responses = {
			{status = 404, body = '{"error":{"code":"itemNotFound","message":"The session specified in the request does not exist or is invalid due to a transient error.","innerError":{"code":"invalidSessionReCreatable"}}}'},
			{status = 409, body = '{"error":{"code":"conflict","message":"A table can\'t overlap another table.","innererror":{"code":"itemAlreadyExists"}}}'},
			{status = 503, headers = {["retry-after"] = {"30"}}, body = '{"error":{"code":"serviceUnavailable","message":"Try later"}}'},
			{status = 409, body = '{"error":{"code":"nameAlreadyExists","message":"The specified item name already exists."}}'},
		}
		fails({"HTTP 404 (itemNotFound)", "session specified in the request", "; innerError: invalidSessionReCreatable", '"retryable":false'}, c.ranges.update, {itemId = "I1", address = "Sheet1!A1", values = {{1}}, sessionId = "old"})
		fails({"HTTP 409 (conflict)", "overlap another table", "; innerError: itemAlreadyExists", '"retryable":false'}, c.tables.add, {itemId = "I1", address = "Sheet1!A1:B2"})
		fails({"HTTP 503 (serviceUnavailable)", "Retry-After: 30", '"retryable":false'}, c.tables.addRows, {itemId = "I1", table = "Table1", values = {{1, 2, 3}}})
		fails({"HTTP 409 (nameAlreadyExists)", "already exists", '"retryable":false'}, c.workbooks.create, {name = "Budget 2026.xlsx"})
	end,
}
