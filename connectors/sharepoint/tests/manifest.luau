return {
	contract = function(m)
		local graph = "https://graph.microsoft.com/v1.0"
		local site = graph .. "/sites/contoso.sharepoint.com,2c3f5e86-9b5e-4b8a-a2a5-4e3c1d5a7b90,712a596e-90a1-49e3-9b48-bfa80bee8740"
		local encoded = graph .. "/sites/contoso.sharepoint.com%2C2c3f5e86-9b5e-4b8a-a2a5-4e3c1d5a7b90%2C712a596e-90a1-49e3-9b48-bfa80bee8740"
		local drive = graph .. "/drives/b!hl4_LF6bikuipU48HVp7kG5Z"
		local reading = {"search", "sites.search", "sites.get", "sites.listFollowed", "sites.listSubsites", "files.listDrives", "files.getDrive",
			"files.get", "files.listChildren", "files.search", "files.download", "lists.list", "lists.get", "lists.listColumns", "lists.listItems",
			"lists.getItem", "pages.list", "pages.get"}
		for access, expected in {read = reading, write = m.concat(reading, {"files.createFolder", "files.upload", "files.update", "files.copy",
			"files.delete", "lists.createItem", "lists.updateItem", "lists.deleteItem"})} do
			local result, err = m.exports({}, "oauth", nil, nil, {data = access})
			assert(result and not err and result.type == "result", tostring(err or result.error))
			m.sortedEqual(expected, result.exports)
		end
		for access, scope in {read = "Sites.Read.All", write = "Sites.ReadWrite.All"} do
			local r, err = m.resolve({client_id = "publisher-client", client_secret = "publisher-secret"}, {}, nil, "oauth", {data = access})
			assert(r and not err, tostring(err))
			assert(m.equal(r.Scopes, {"offline_access", "User.Read", scope}), "requested OAuth scopes for " .. access)
			r.Context.Auth.oauth.access_token = "fixture-token"
			local reads = {
				"GET " .. graph .. "/sites?search=marketing&$select=id", "GET " .. graph .. "/sites/root", "GET " .. site, "GET " .. encoded,
				"GET " .. graph .. "/sites/contoso.sharepoint.com", "GET " .. graph .. "/sites/contoso.sharepoint.com:/sites/marketing",
				"GET " .. graph .. "/sites/contoso.sharepoint.com:/teams/launch?$select=id", "GET " .. site .. "/sites",
				"GET " .. graph .. "/sites/contoso-my.sharepoint.com:/personal/ana_contoso_com",
				"GET " .. graph .. "/me/followedSites", "GET " .. site .. "/drive", "GET " .. encoded .. "/drives",
				"GET " .. drive, "GET " .. drive .. "/root", "GET " .. graph .. "/drives/b%21hl4/root/children", "GET " .. drive .. "/root/children?$skiptoken=MjAx",
				"GET " .. drive .. "/root/search(q='10:30%20notes')", "GET " .. drive .. "/root:/Proposals/Q3%20plan.docx:",
				"GET " .. drive .. "/items/01ABC", "GET " .. drive .. "/items/01ABC/children", "GET " .. drive .. "/items/01ABC/content?format=pdf",
				"GET " .. site .. "/lists", "GET " .. site .. "/lists/Projects", "GET " .. site .. "/lists/L1/columns",
				"GET " .. site .. "/lists/L1/items?$expand=fields(select=Title,Status)&$filter=fields/Status%20eq%20'Done'",
				"GET " .. site .. "/lists/L1/items/4?$expand=fields", "GET " .. site .. "/pages?$top=20",
				"GET " .. site .. "/pages/P1/microsoft.graph.sitePage?$expand=canvasLayout",
				"POST " .. graph .. "/search/query",
			}
			m.routes(r, "Bearer fixture-token", true, reads)
			m.rejectOverrides(r, reads)
			-- Content redirects to preauthenticated hosts, which never receive the token.
			m.routes(r, "", true, {
				"GET https://contoso.sharepoint.com/sites/marketing/_layouts/15/download.aspx?UniqueId=1&tempauth=abc",
				"GET https://contoso-my.sharepoint.com/personal/ana/_layouts/15/download.aspx?UniqueId=1&tempauth=abc",
				"GET https://westus1-mediap.svc.ms/transform/pdf?provider=spo",
			})
			local writes = {
				"POST " .. drive .. "/root/children", "POST " .. drive .. "/items/01ABC/children", "POST " .. drive .. "/items/01ABC/copy",
				"POST " .. site .. "/lists/L1/items", "PATCH " .. drive .. "/items/01ABC", "PATCH " .. site .. "/lists/L1/items/4/fields",
				"DELETE " .. drive .. "/items/01ABC", "DELETE " .. site .. "/lists/L1/items/4", "PUT " .. drive .. "/items/01ABC/content",
				"PUT " .. drive .. "/root:/plan.pdf:/content?@microsoft.graph.conflictBehavior=rename",
				"PUT " .. drive .. "/items/01ABC:/Q3%20plan.pdf:/content?@microsoft.graph.conflictBehavior=replace",
			}
			m.routes(r, "Bearer fixture-token", access == "write", writes)
			if access == "write" then m.rejectOverrides(r, writes) end
			-- Deferred features stay refused at every level: sharing, link redemption, list and column
			-- creation, page writes, item writes outside fields, check-out, following, upload sessions and
			-- permanent deletes. The path rules root/{search} and root:/* also match root/permissions and a
			-- path-addressed item's permissions, which the matcher cannot narrow: the connector builds those
			-- URLs itself and follows only nextLinks of its own routes (reads.luau).
			m.routes(r, "Bearer fixture-token", false, {
				"GET " .. drive .. "/items/01ABC/permissions", "POST " .. drive .. "/items/01ABC/createLink",
				"POST " .. drive .. "/items/01ABC/invite", "DELETE " .. drive .. "/items/01ABC/permissions/p1",
				"GET " .. graph .. "/shares/u!abc/driveItem", "POST " .. site .. "/lists", "POST " .. site .. "/lists/L1/columns",
				"POST " .. site .. "/pages", "PATCH " .. site .. "/pages/P1/microsoft.graph.sitePage",
				"POST " .. site .. "/pages/P1/microsoft.graph.sitePage/publish", "PATCH " .. site .. "/lists/L1/items/4",
				"POST " .. drive .. "/items/01ABC/checkin", "POST " .. drive .. "/items/01ABC/checkout",
				"POST " .. graph .. "/me/followedSites/add", "POST " .. graph .. "/me/followedSites/remove",
				"POST " .. drive .. "/items/01ABC/createUploadSession", "POST " .. drive .. "/items/01ABC:/x.pdf:/createUploadSession",
				"POST " .. drive .. "/items/01ABC/permanentDelete", "DELETE " .. site .. "/lists/L1",
			})
			-- The token stays off other Graph surfaces, Microsoft's token endpoint, batches, beta, colon
			-- tricks on site paths, lookalike hosts and other POST routes.
			m.routes(r, "Bearer fixture-token", false, {
				"GET " .. graph .. "/me", "GET " .. graph .. "/me/drive", "GET " .. graph .. "/me/drives", "GET " .. graph .. "/me/messages",
				"GET " .. graph .. "/users/ana@contoso.com/drive", "GET " .. graph .. "/groups/g1/drive", "GET " .. graph .. "/drives",
				"GET " .. drive .. "/items/01ABC/workbook/worksheets", "GET " .. site .. "/permissions", "GET " .. site .. "/onenote/pages",
				"GET " .. site .. "/termStore/groups", "POST " .. graph .. "/$batch", "GET https://graph.microsoft.com/beta/sites/root",
				"POST https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
				"GET " .. graph .. "/sites/contoso.sharepoint.com:/sites/marketing:/lists",
				"GET " .. graph .. "/sites/contoso.sharepoint.com:/sites/marketing:", "GET " .. graph .. "/sites/contoso.sharepoint.com:/sites/marketing%3A", "GET " .. graph .. "/sites/contoso.sharepoint.com:/lists",
				"GET " .. graph .. "/sites/contoso.sharepoint.com%3A/drives", "GET " .. graph .. "/sites/a:b/drives",
				"POST " .. graph .. "/sites/contoso.sharepoint.com:/sites/marketing", "POST " .. graph .. "/search/acronyms",
				"POST " .. site .. "/drives", "GET " .. drive .. "/items/01ABC%2F..%2Fx",
				"GET https://graph.microsoft.com.evil.test/v1.0/sites/root",
			})
			-- Preauthenticated hosts take no writes, and lookalike hosts get nothing.
			m.routes(r, "", false, {
				"PUT https://contoso.sharepoint.com/upload", "POST https://contoso.sharepoint.com/_api/web",
				"GET https://sharepoint.com/x", "GET https://contoso.sharepoint.com.evil.test/x",
				"GET https://evil.test/contoso.sharepoint.com/x", "GET https://x.files.1drv.com/y",
			})
		end
	end,
}
