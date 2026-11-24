return {
	scenario = {publisher = {client_id = "fixture-client", client_secret = "fixture-private-secret"}, config = {}, auth_method = "oauth", auth_config = {}},
	access = {data = "read"},
	configure = function()
		requests, responses = {}, {}
		fs = fixture.files()
		http = {request = function(req)
			assert(req.headers == nil or req.headers.Authorization == nil, "the proxy injects Authorization")
			table.insert(requests, req)
			assert(#responses > 0, "unexpected request: " .. req.url)
			local response = table.remove(responses, 1)
			return fixture.operation({statusCode = response.status or 200, headers = response.headers or {}, body = fixture.reader(response.body or "")})
		end}
	end,
	run = function(c)
		local function fails(expected: {string}, fn: (...any) -> any, ...: any)
			local ok, err = pcall(fn, ...)
			assert(not ok, "call succeeded")
			for _, text in expected do assert(string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err)) end
		end
		local function last() return requests[#requests] end
		local GRAPH = "https://graph.microsoft.com/v1.0"
		local SITE_ID = "contoso.sharepoint.com,2c3f5e86,712a596e"
		local SITE = GRAPH .. "/sites/contoso.sharepoint.com%2C2c3f5e86%2C712a596e"
		local DRIVE = GRAPH .. "/drives/b%21hl4"
		local ITEM = "$select=id%2Cname%2Csize%2Cfile%2Cfolder%2Cpackage%2CparentReference%2CcreatedDateTime%2ClastModifiedDateTime%2CwebUrl"
		local SITES = "$select=id%2CdisplayName%2Cname%2CwebUrl%2Cdescription%2ClastModifiedDateTime"
		local UA = "ISV|AIBakery|Houston/1.0"

		-- Search sends one SharePoint-only request and drops preauthenticated links from hits.
		responses = {{body = '{"value":[{"hitsContainers":[{"total":1,"moreResultsAvailable":false,"hits":[{"hitId":"h1","resource":{"id":"f1",'
			.. '"parentReference":{"driveId":"b!hl4"},"@microsoft.graph.downloadUrl":"https://contoso.sharepoint.com/download.aspx?tempauth=secret"}}]}]}]}'}}
		local found = c.search({queryString = "budget filetype:xlsx", size = 10})
		local hit = found.value[1].hitsContainers[1].hits[1].resource
		assert(hit.id == "f1" and hit.parentReference.driveId == "b!hl4" and hit["@microsoft.graph.downloadUrl"] == nil)
		assert(last().method == "POST" and last().url == GRAPH .. "/search/query" and last().headers["Content-Type"][1] == "application/json", last().url)
		assert(last().headers["User-Agent"][1] == UA, "Graph calls identify Houston in Microsoft's ISV format")
		local body = json.decode(last().body)
		assert(#body.requests == 1 and body.requests[1].query.queryString == "budget filetype:xlsx" and body.requests[1].size == 10, last().body)
		assert(json.encode(body.requests[1].entityTypes) == '["driveItem"]', "search defaults to files")
		responses = {{body = '{"value":[]}'}}
		c.search({queryString = "launch", entityTypes = {"listItem", "site"}, from = 25, size = 25, fields = {"Title"}, sortProperties = {{name = "lastModifiedDateTime", isDescending = true}}})
		local sent = json.decode(last().body).requests[1]
		local keys = {}
		for key in sent do table.insert(keys, key) end
		table.sort(keys)
		assert(table.concat(keys, ",") == "entityTypes,fields,from,query,size,sortProperties", table.concat(keys, ","))
		assert(sent.entityTypes[2] == "site" and sent.from == 25 and sent.sortProperties[1].isDescending == true)

		-- Sites by search, ID, URL, following and parent.
		local nextSites = GRAPH .. "/sites?search=marketing&$skiptoken=X"
		responses = {{body = '{"value":[{"id":"' .. SITE_ID .. '"}],"@odata.nextLink":"' .. nextSites .. '"}'}, {body = '{}'}}
		local found_sites = c.sites.search({search = "marketing", top = 10})
		assert(last().url == GRAPH .. "/sites?search=marketing&" .. SITES .. "&$top=10", last().url)
		assert(found_sites.value[1].id == SITE_ID and found_sites["@odata.nextLink"] == nextSites)
		assert(json.encode(c.sites.search({nextLink = nextSites}).value) == "[]" and last().url == nextSites)
		responses = {{body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}}
		c.sites.get({siteId = SITE_ID})
		assert(last().url == SITE .. "?" .. SITES and last().headers["User-Agent"][1] == UA, last().url)
		c.sites.get({webUrl = "https://Contoso.SharePoint.com/sites/marketing/SitePages/Home.aspx", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com:/sites/marketing?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso.sharepoint.com/Teams/launch-2026", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com:/teams/launch-2026?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso-my.sharepoint.com/personal/ana_contoso_com/Documents/plan.docx", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso-my.sharepoint.com:/personal/ana_contoso_com?$select=id", last().url)
		-- Office's copied links prefix the path: r and g keep it whole, s abbreviates /sites.
		responses = {{body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}, {body = '{"id":"s"}'}}
		c.sites.get({webUrl = "https://contoso.sharepoint.com/:x:/r/sites/marketing/Shared%20Documents/budget.xlsx?d=w1", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com:/sites/marketing?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso.sharepoint.com/:f:/s/marketing/EaBcToken", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com:/sites/marketing?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso-my.sharepoint.com/:w:/g/personal/ana_contoso_com/EToken", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso-my.sharepoint.com:/personal/ana_contoso_com?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso.sharepoint.com/Shared%20Documents/plan.docx", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com?$select=id", last().url)
		c.sites.get({webUrl = "https://contoso.sharepoint.com", select = "id"})
		assert(last().url == GRAPH .. "/sites/contoso.sharepoint.com?$select=id", last().url)
		responses = {{body = '{}'}, {body = '{"value":[]}'}}
		c.sites.listFollowed()
		assert(last().url == GRAPH .. "/me/followedSites?" .. SITES, last().url)
		c.sites.listSubsites({siteId = SITE_ID, top = 5})
		assert(last().url == SITE .. "/sites?" .. SITES .. "&$top=5", last().url)

		-- Document libraries and their items.
		responses = {{body = '{"value":[{"id":"b!hl4"}]}'}, {body = '{"id":"b!hl4"}'}, {body = '{"id":"b!hl4"}'}}
		assert(c.files.listDrives({siteId = SITE_ID}).value[1].id == "b!hl4")
		assert(last().url == SITE .. "/drives?$select=id%2Cname%2CdriveType%2CwebUrl", last().url)
		c.files.getDrive({siteId = SITE_ID})
		assert(last().url == SITE .. "/drive", last().url)
		c.files.getDrive({driveId = "b!hl4", select = {"id", "quota"}})
		assert(last().url == DRIVE .. "?$select=id,quota", last().url)
		responses = {{body = '{"id":"f2","@microsoft.graph.downloadUrl":"https://contoso.sharepoint.com/x","@content.downloadUrl":"https://contoso.sharepoint.com/y"}'}, {body = '{"id":"root"}'}}
		local item = c.files.get({driveId = "b!hl4", path = "/Proposals/Q3 plan.docx"})
		assert(item.id == "f2" and item["@microsoft.graph.downloadUrl"] == nil and item["@content.downloadUrl"] == nil)
		assert(last().url == DRIVE .. "/root:/Proposals/Q3%20plan.docx:?" .. ITEM, last().url)
		c.files.get({driveId = "b!hl4"})
		assert(last().url == DRIVE .. "/root?" .. ITEM, last().url)
		local nextChildren = GRAPH .. "/drives('b!hl4')/items('01ABC')/children?%24skiptoken=UGFn"
		responses = {{body = '{"value":[{"id":"c1"}],"@odata.nextLink":"' .. nextChildren .. '"}'}, {body = '{}'}, {body = '{"value":[]}'}}
		c.files.listChildren({driveId = "b!hl4", itemId = "01ABC", top = 50, orderby = "name"})
		assert(last().url == DRIVE .. "/items/01ABC/children?" .. ITEM .. "&$top=50&$orderby=name", last().url)
		assert(json.encode(c.files.listChildren({nextLink = nextChildren}).value) == "[]")
		assert(last().url == GRAPH .. "/drives/b!hl4/items/01ABC/children?%24skiptoken=UGFn", last().url)
		c.files.search({driveId = "b!hl4", q = "O'Brien plan", top = 5})
		assert(last().url == DRIVE .. "/root/search(q='O%27%27Brien%20plan')?" .. ITEM .. "&$top=5", last().url)

		-- Content redirects to a preauthenticated host, fetched without credentials.
		local signed = "https://contoso.sharepoint.com/sites/marketing/_layouts/15/download.aspx?UniqueId=1&tempauth=abc"
		local bytes = string.char(0, 255) .. "plan"
		responses = {{status = 302, headers = {location = {signed}}}, {body = bytes}}
		local saved = c.files.download({driveId = "b!hl4", itemId = "01ABC", path = "downloads/plan.docx"})
		assert(requests[#requests - 1].url == DRIVE .. "/items/01ABC/content" and last().url == signed)
		assert(requests[#requests - 1].headers["User-Agent"][1] == UA and last().headers["User-Agent"][1] == UA)
		assert(saved.path == "downloads/plan.docx" and saved.size == #bytes and saved.url == "https://houston.test/downloads/plan.docx")
		responses = {{status = 302, headers = {location = {"https://westus1-mediap.svc.ms/transform/pdf?provider=spo"}}}, {body = "%PDF"}}
		assert(c.files.download({driveId = "b!hl4", itemId = "01ABC", path = "plan.pdf", format = "pdf"}).size == 4)
		assert(requests[#requests - 1].url == DRIVE .. "/items/01ABC/content?format=pdf", requests[#requests - 1].url)
		for _, location in {"https://evil.example/download", "https://sharepoint.com.evil.example/x", "http://contoso.sharepoint.com/x", "https://x.files.1drv.com/y"} do
			sent = #requests
			responses = {{status = 302, headers = {location = {location}}}}
			fails({"unexpected host", '"retryable":false'}, c.files.download, {driveId = "b!hl4", itemId = "01ABC", path = "x.bin"})
			assert(#requests == sent + 1, location)
		end
		responses = {{status = 302, headers = {location = {signed}}}, {status = 403, body = "expired"}}
		fails({"download link failed with HTTP 403; call again for a fresh link", '"retryable":true'}, c.files.download, {driveId = "b!hl4", itemId = "01ABC", path = "expired.bin"})
		assert(not await(fs.exists("expired.bin")), "a failed download published a file")

		-- Lists, columns and items, with the items' fields expanded.
		responses = {{body = '{"value":[{"id":"L1"}]}'}, {body = '{"id":"L1"}'}, {body = '{"value":[{"name":"Status","indexed":true}]}'}}
		c.lists.list({siteId = SITE_ID})
		assert(last().url == SITE .. "/lists?$select=id%2Cname%2CdisplayName%2Cdescription%2CwebUrl%2Clist%2ClastModifiedDateTime", last().url)
		c.lists.get({siteId = SITE_ID, listId = "Project Tracker", select = "id"})
		assert(last().url == SITE .. "/lists/Project%20Tracker?$select=id", last().url)
		assert(c.lists.listColumns({siteId = SITE_ID, listId = "L1"}).value[1].indexed)
		assert(last().url == SITE .. "/lists/L1/columns", last().url)
		local nextItems = SITE .. "/lists/L1/items?%24expand=fields(select%3DTitle%2CStatus)&%24skiptoken=UGFn"
		responses = {{body = '{"value":[{"id":"4","fields":{"Title":"Launch"}}],"@odata.nextLink":"' .. nextItems .. '"}'}, {body = '{}'}, {body = '{"value":[]}'}, {body = '{"id":"4"}'}}
		local rows = c.lists.listItems({siteId = SITE_ID, listId = "L1", fields = {"Title", "Status"}, filter = "fields/Status eq 'Done'", orderby = "fields/Modified desc", top = 50})
		assert(last().url == SITE .. "/lists/L1/items?$expand=fields(select=Title,Status)&$filter=fields%2FStatus%20eq%20%27Done%27&$orderby=fields%2FModified%20desc&$top=50", last().url)
		assert(rows.value[1].fields.Title == "Launch")
		-- Graph filters and sorts on unindexed columns only with this header, on every page.
		assert(last().headers.Prefer[1] == "HonorNonIndexedQueriesWarningMayFailRandomly")
		assert(json.encode(c.lists.listItems({nextLink = nextItems}).value) == "[]")
		assert(last().url == SITE .. "/lists/L1/items?%24skiptoken=UGFn&%24expand=fields(select%3DTitle%2CStatus)", last().url)
		assert(last().headers.Prefer[1] == "HonorNonIndexedQueriesWarningMayFailRandomly")
		c.lists.listItems({nextLink = SITE .. "/lists/L1/items?$skiptoken=1"})
		assert(last().url == SITE .. "/lists/L1/items?$skiptoken=1", last().url)
		c.lists.getItem({siteId = SITE_ID, listId = "L1", itemId = "4", fields = "Title, Status"})
		assert(last().url == SITE .. "/lists/L1/items/4?$expand=fields(select=Title,Status)", last().url)

		-- Pages, with their content.
		responses = {{body = '{"value":[]}'}, {body = '{"id":"P1","canvasLayout":{}}'}}
		c.pages.list({siteId = SITE_ID, top = 20, filter = "pageLayout eq 'article'"})
		assert(last().url == SITE .. "/pages?$top=20&$filter=pageLayout%20eq%20%27article%27", last().url)
		assert(c.pages.get({siteId = SITE_ID, pageId = "P1", select = "id,title"}).id == "P1")
		assert(last().url == SITE .. "/pages/P1/microsoft.graph.sitePage?$expand=canvasLayout&$select=id%2Ctitle", last().url)

		-- Each list follows only its own nextLinks: a link to another route, such as a path-addressed
		-- item's permissions, which the proxy's path rules would pass, never reaches Graph.
		local RAW = GRAPH .. "/sites/contoso.sharepoint.com,2c3f5e86,712a596e"
		for _, case in {
			{c.sites.search, GRAPH .. "/sites?search=x&$skiptoken=1", RAW .. "/lists?$skiptoken=1"},
			{c.sites.listFollowed, GRAPH .. "/me/followedSites?$skiptoken=1", RAW .. "/drives"},
			{c.sites.listSubsites, RAW .. "/sites?$skiptoken=1", GRAPH .. "/drives/b!1/root:/x/sites"},
			{c.files.listDrives, RAW .. "/drives?$skiptoken=1", GRAPH .. "/drives/b!1/root:/a/drives"},
			{c.files.listChildren, GRAPH .. "/drives/b!1/root/children?$skiptoken=1", GRAPH .. "/drives/b!1/root:/x.docx:/permissions/children"},
			{c.files.search, GRAPH .. "/drives/b!1/root/microsoft.graph.search(q='x')?$skiptoken=1", GRAPH .. "/drives/b!1/root:/x.docx:/permissions/a.search()"},
			{c.lists.list, RAW .. "/lists?$skiptoken=1", GRAPH .. "/drives/b!1/root:/lists"},
			{c.lists.listColumns, RAW .. "/lists/L1/columns?$skiptoken=1", RAW .. "/lists/L1/items/4/columns"},
			{c.lists.listItems, RAW .. "/lists/L1/items?$skiptoken=1&$expand=fields($select=Title)", GRAPH .. "/drives/b!1/root:/lists/x/items?$expand=fields"},
			{c.lists.listItems, RAW .. "/lists/L1/items?$skiptoken=1&expand=fields", RAW .. "/lists/L1/items/4/versions"},
			{c.pages.list, RAW .. "/pages?$skiptoken=1", GRAPH .. "/drives/b!1/root:/pages"},
		} :: {any} do
			responses = {{body = '{"value":[]}'}}
			case[1]({nextLink = case[2]})
			assert(last().url == case[2], last().url)
			sent = #requests
			assert(not pcall(case[1], {nextLink = case[3]}), case[3])
			assert(#requests == sent, case[3])
		end

		-- Invalid input never reaches Graph.
		sent = #requests
		for _, call in {
			function() return c.search({}) end,
			function() return c.search({queryString = "x", entityTypes = {"message"}}) end,
			function() return c.search({queryString = "x", entityTypes = {"driveItem", "event"}}) end,
			function() return c.search({queryString = "x", entityTypes = {}}) end,
			function() return c.search({queryString = "x", size = 501}) end,
			function() return c.search({queryString = "x", from = -1}) end,
			function() return c.search({queryString = "x", contentSources = {"/external/connections/x"}}) end,
			function() return c.search({queryString = "x", region = "NAM"}) end,
			function() return c.search({queryString = "x", entityTypes = {"drive"}, sortProperties = {{name = "name"}}}) end,
			function() return c.search({queryString = "x", sortProperties = {{name = "name", extra = true}}}) end,
			function() return c.sites.search({}) end,
			function() return c.sites.search({nextLink = nextSites, top = 5}) end,
			function() return c.sites.get({siteId = SITE_ID, webUrl = "https://contoso.sharepoint.com"}) end,
			function() return c.sites.get({webUrl = "https://evil.example/sites/x"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.com.evil.example/sites/x"}) end,
			function() return c.sites.get({webUrl = "http://contoso.sharepoint.com/sites/x"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.com/sites/..%2F"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.com/sites/a:b"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.comx/sites/a"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.com/:u:/x/Token"}) end,
			function() return c.sites.get({webUrl = "https://contoso.sharepoint.com/:w:"}) end,
			function() return c.sites.get({siteId = "a/b"}) end,
			function() return c.files.getDrive({}) end,
			function() return c.files.getDrive({driveId = "b!1", siteId = "root"}) end,
			function() return c.files.get({path = "x"}) end,
			function() return c.files.get({driveId = "b!1", path = "Documents/../secret"}) end,
			function() return c.files.get({driveId = "b!1", path = "photo.jpg:/thumbnails"}) end,
			function() return c.files.get({driveId = "b!1", itemId = "f1", path = "a"}) end,
			function() return c.files.listChildren({driveId = "b!1", itemId = ".."}) end,
			function() return c.files.listChildren({nextLink = GRAPH .. "/drives/b!1/root/children", top = 5}) end,
			function() return c.files.listChildren({nextLink = "https://evil.example/v1.0/drives/b!1/root/children"}) end,
			function() return c.files.listChildren({nextLink = GRAPH .. "/drives/b!1/root/children?$expand=thumbnails"}) end,
			function() return c.files.search({driveId = "b!1", q = "a/b"}) end,
			function() return c.files.download({driveId = "b!1", itemId = "f1"}) end,
			function() return c.files.download({driveId = "b!1", itemId = "f1", path = "x.jpg", format = "jpg"}) end,
			function() return c.lists.listItems({siteId = SITE_ID, listId = "L1", fields = {"Title,Status"}}) end,
			function() return c.lists.listItems({siteId = SITE_ID, listId = "L1", fields = "Title)"}) end,
			function() return c.lists.listItems({siteId = SITE_ID, listId = "L1", fields = {}}) end,
			function() return c.lists.listItems({siteId = SITE_ID, listId = "L1", expand = "x"}) end,
			function() return c.lists.listItems({nextLink = nextItems, top = 5}) end,
			-- An item page's nextLink may expand only the fields, and must page the same list's items.
			function() return c.lists.listItems({nextLink = SITE .. "/lists/L1/items?$expand=driveItem"}) end,
			function() return c.lists.listItems({nextLink = SITE .. "/lists/L1/items?%24expand=fields&%24expand=fields"}) end,
			function() return c.lists.listItems({nextLink = SITE .. "/lists/L1/items?$expand=fields($expand=driveItem)"}) end,
			function() return c.lists.listItems({nextLink = SITE .. "/lists/L1/columns?$expand=fields"}) end,
			function() return c.lists.listItems({nextLink = GRAPH .. "/me/messages?$expand=fields"}) end,
			function() return c.lists.getItem({siteId = SITE_ID, listId = "L1"}) end,
			function() return c.pages.get({siteId = SITE_ID, pageId = "P1", expand = "x"}) end,
		} do assert(not pcall(call)) end
		assert(#requests == sent, "invalid input reached Graph")

		-- Graph errors keep the status, code and message; throttling is retryable.
		responses = {{status = 404, body = '{"error":{"code":"itemNotFound","message":"The resource could not be found."}}'}}
		fails({"Microsoft Graph HTTP 404 (itemNotFound): The resource could not be found.", '"retryable":false'}, c.files.get, {driveId = "b!1", itemId = "missing"})
		responses = {{status = 429, headers = {["retry-after"] = {"7"}}, body = '{"error":{"code":"TooManyRequests","message":"Slow down"}}'}}
		fails({"Microsoft Graph HTTP 429 (TooManyRequests): Slow down; Retry-After: 7", '"retryable":true'}, c.lists.listItems, {siteId = SITE_ID, listId = "L1"})
		responses = {{status = 503, body = "<html>unavailable</html>"}}
		fails({"Microsoft Graph HTTP 503", '"retryable":true'}, c.search, {queryString = "x"})
		responses = {{status = 400, body = '{"error":{"code":"invalidRequest","message":"Field \'Status\' cannot be referenced in filter or orderby as it is not indexed."}}'}}
		fails({"HTTP 400 (invalidRequest)", "not indexed", '"retryable":false'}, c.lists.listItems, {siteId = SITE_ID, listId = "L1", filter = "fields/Status eq 'Done'"})
		responses = {{status = 200, body = "[1]"}}
		fails({"invalid JSON object"}, c.sites.get, {siteId = "root"})
		assert(#responses == 0)
	end,
}
