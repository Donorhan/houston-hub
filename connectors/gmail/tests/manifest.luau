return {
	contract = function(m)
		local api = "https://gmail.googleapis.com/gmail/v1/users/me"
		local upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me"
		local function google(access, scopes)
			local r, err = m.resolve({ client_id = "publisher-client", client_secret = "publisher-secret" }, {}, nil, "oauth", access)
			assert(r and not err, tostring(err))
			local want = { "https://www.googleapis.com/auth/userinfo.email" }
			for _, scope in scopes do
				table.insert(want, "https://www.googleapis.com/auth/" .. scope)
			end
			assert(m.equal(r.Scopes, want), "requested OAuth scopes: " .. table.concat(r.Scopes, " "))
			r.Context.Auth.oauth.access_token = "fixture-token"
			return r
		end
		-- Routes of a row's level, allowed only from that level up.
		local function gated(r, allowed, routes)
			m.routes(r, "Bearer fixture-token", allowed, routes)
			if allowed then
				m.rejectOverrides(r, routes)
			end
		end
		do
			local _, err = m.resolve({ client_id = "publisher-client", client_secret = "publisher-secret" }, {}, nil, "oauth", { messages = "none", drafts = "none", sending = "none" })
			assert(string.find(tostring(err), "raise at least one access row", 1, true), "a connection with every row on None must be refused: " .. tostring(err))
		end
		for _, case in
			{
				{ access = { messages = "read", drafts = "none", sending = "none" }, scopes = { "gmail.messages.readonly", "gmail.labels.readonly" } },
				{
					access = { messages = "organize", drafts = "none", sending = "none" },
					scopes = { "gmail.messages.readonly", "gmail.messages.modify", "gmail.labels" },
				},
				{ access = { messages = "none", drafts = "create", sending = "none" }, scopes = { "gmail.drafts.create" } },
				{ access = { messages = "none", drafts = "manage", sending = "none" }, scopes = { "gmail.drafts" } },
				{ access = { messages = "none", drafts = "none", sending = "send" }, scopes = { "gmail.send" } },
				{
					access = { messages = "read", drafts = "create", sending = "send" },
					scopes = { "gmail.messages.readonly", "gmail.labels.readonly", "gmail.drafts.create", "gmail.send" },
				},
				{
					access = { messages = "organize", drafts = "manage", sending = "send" },
					scopes = { "gmail.messages.readonly", "gmail.messages.modify", "gmail.labels", "gmail.drafts", "gmail.send" },
				},
			}
		do
			local access = case.access
			local r = google(access, case.scopes)
			gated(r, access.messages ~= "none", {
				"GET " .. api .. "/labels",
				"GET " .. api .. "/labels/Label_1",
				"GET " .. api .. "/messages?q=is%3Aunread",
				"GET " .. api .. "/messages/m1?format=full",
				"GET " .. api .. "/messages/m1/attachments/a1",
				"GET " .. api .. "/threads",
				"GET " .. api .. "/threads/t1",
				"GET " .. api .. "/history?startHistoryId=1",
				"GET https://www.googleapis.com/oauth2/v2/userinfo",
			})
			gated(r, access.messages == "organize", {
				"POST " .. api .. "/messages/batchModify",
				"POST " .. api .. "/messages/m1/modify",
				"POST " .. api .. "/threads/t1/modify",
				"POST " .. api .. "/labels",
				"PATCH " .. api .. "/labels/Label_1",
				"DELETE " .. api .. "/labels/Label_1",
			})
			gated(r, access.drafts ~= "none", { "POST " .. upload .. "/drafts?uploadType=multipart" })
			gated(r, access.drafts == "manage", {
				"GET " .. api .. "/drafts",
				"GET " .. api .. "/drafts/d1",
				"PUT " .. upload .. "/drafts/d1?uploadType=multipart",
				"DELETE " .. api .. "/drafts/d1",
			})
			gated(r, access.sending == "send", { "POST " .. upload .. "/messages/send?uploadType=multipart" })
			m.routes(r, "Bearer fixture-token", false, {
				"POST https://oauth2.googleapis.com/token",
				"GET https://www.googleapis.com/drive/v3/files",
				"GET https://www.googleapis.com/oauth2/v2/tokeninfo",
				"POST https://www.googleapis.com/oauth2/v2/userinfo",
				"GET https://gmail.googleapis.com.evil.test/gmail/v1/users/me/labels",
				"GET https://www.googleapis.com/gmail/v1/users/me/labels",
				"GET https://gmail.googleapis.com/gmail/v1/users/other@example.com/labels",
				"GET " .. api .. "/profile",
				"POST https://gmail.googleapis.com/batch/gmail/v1",
				"DELETE " .. api .. "/messages/m1",
				"POST " .. api .. "/messages/batchDelete",
				"POST " .. api .. "/messages/m1/trash",
				"POST " .. api .. "/messages/m1/untrash",
				"DELETE " .. api .. "/threads/t1",
				"POST " .. api .. "/threads/t1/trash",
				"POST " .. api .. "/threads/t1/untrash",
				"POST " .. api .. "/messages/import",
				"POST " .. api .. "/messages",
				"POST " .. api .. "/messages/send",
				"POST " .. api .. "/drafts/send",
				"POST " .. upload .. "/drafts/send?uploadType=multipart",
				"POST " .. upload .. "/drafts/d1?uploadType=multipart",
				"POST " .. upload .. "/messages/import",
				"POST " .. upload .. "/messages",
				"PUT " .. api .. "/labels/Label_1",
				"PUT " .. api .. "/drafts/d1",
				"POST " .. api .. "/drafts",
				"POST " .. api .. "/watch",
				"POST " .. api .. "/stop",
				"GET " .. api .. "/settings/sendAs",
				"GET " .. api .. "/settings/forwardingAddresses",
				"POST " .. api .. "/settings/filters",
				"PUT " .. api .. "/settings/vacation",
				"GET " .. api .. "/messages/%2e%2e/profile",
				"GET " .. api .. "/messages/m1%2F..%2Fx",
			})
		end
		do
			local drafts = google({ messages = "read", drafts = "manage", sending = "none" }, { "gmail.messages.readonly", "gmail.labels.readonly", "gmail.drafts" })
			for _, name in { "$httpMethod", "%24httpMethod" } do
				m.refused(drafts, "method override", {
					"GET " .. api .. "/drafts/send?" .. name .. "=POST",
					"GET " .. api .. "/messages/send?" .. name .. "=POST",
					"PUT " .. upload .. "/drafts/send?" .. name .. "=POST",
				})
			end
		end
	end,
}
