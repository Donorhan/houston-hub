return {
	contract = function(m)
		-- TestSlackPublisherOwnedClient
		do
			if not (m.publisherClient(m.raw.auth["oauth"])) then
				m.fail("Slack OAuth client must belong to the publication")
			end
		end
		-- TestSlackScopesAndAccessRoutes
		do
			local base = {
				"GET https://slack.com/api/auth.test",
				"GET https://slack.com/api/users.conversations?types=im",
				"GET https://slack.com/api/conversations.history?channel=C1",
				"GET https://slack.com/api/conversations.replies?channel=C1&ts=1.2",
				"GET https://slack.com/api/conversations.info?channel=C1",
				"GET https://slack.com/api/conversations.members?channel=C1",
				"GET https://slack.com/api/chat.getPermalink?channel=C1&message_ts=1.2",
			}
			local conversations = { "getChannel", "getPermalink", "getThread", "listChannels", "listMembers", "listMessages" }
			-- In scope group order; each entry is active when its row allows its level.
			local gates = {
				{ row = "channels", level = "read", scopes = { "channels:read", "channels:history" }, exports = conversations },
				{ row = "private_channels", level = "read", scopes = { "groups:read", "groups:history" }, exports = conversations },
				{
					row = "direct_messages",
					level = "read",
					scopes = { "im:read", "im:history", "mpim:read", "mpim:history" },
					exports = conversations,
				},
				{
					row = "users",
					level = "read",
					scopes = { "users:read" },
					routes = { "GET https://slack.com/api/users.info?user=U1", "GET https://slack.com/api/users.list?limit=200" },
					exports = { "getUser", "listUsers" },
				},
				{
					row = "search",
					level = "read",
					scopes = { "search:read" },
					routes = { "GET https://slack.com/api/search.messages?query=hi" },
					exports = { "listMentions", "searchMessages" },
				},
				{
					row = "files",
					level = "read",
					scopes = { "files:read" },
					routes = {
						"GET https://slack.com/api/files.info?file=F1",
						"GET https://files.slack.com/files-pri/T1-F1/download/report.pdf",
						"GET https://files.slack.com/files-pri/T1-F1/download/100%25%20done.pdf",
					},
					exports = { "downloadFile", "getFile" },
				},
				{
					row = "messages",
					level = "write",
					scopes = { "chat:write" },
					routes = {
						"POST https://slack.com/api/chat.postMessage",
						"POST https://slack.com/api/chat.update",
						"POST https://slack.com/api/chat.delete",
					},
					exports = { "deleteMessage", "postMessage", "reply", "updateMessage" },
				},
				{
					row = "files",
					level = "write",
					scopes = { "files:write" },
					routes = {
						"POST https://slack.com/api/files.getUploadURLExternal",
						"POST https://slack.com/api/files.completeUploadExternal",
					},
					unauthenticated = { "POST https://files.slack.com/upload/v1/CwABAAAAXQoAAQ%2FBz%3D" },
					exports = { "uploadFile" },
				},
				{
					row = "direct_messages",
					level = "write",
					scopes = { "im:write", "mpim:write" },
					routes = { "POST https://slack.com/api/conversations.open" },
					exports = { "openConversation" },
				},
				{
					row = "reactions",
					level = "write",
					scopes = { "reactions:write" },
					routes = { "POST https://slack.com/api/reactions.add", "POST https://slack.com/api/reactions.remove" },
					exports = { "addReaction", "removeReaction" },
				},
			}
			local denied = {
				"GET https://slack.com/api/chat.postMessage?channel=C1&text=hi",
				"GET https://slack.com/api/files.getUploadURLExternal?filename=a&length=1",
				"POST https://slack.com/api/oauth.v2.access",
				"GET https://slack.com/api/oauth.v2.access",
				"POST https://slack.com/api/auth.revoke",
				"POST https://slack.com/api/conversations.history",
				"GET https://slack.com/api/users.profile.set",
				"GET https://files.slack.com/upload/v1/signed",
				"POST https://files.slack.com/files-pri/T1-F1/download/report.pdf",
				"GET https://files.slack.com/files-pri/../upload/v1/signed",
				"GET https://slack.com.evil.test/api/auth.test",
				"GET https://evil.slack.com/api/auth.test",
			}
			local rank = { none = 0, read = 1, write = 2 }
			-- Each row's levels above none.
			local rows = {
				channels = { "read" },
				private_channels = { "read" },
				direct_messages = { "read", "write" },
				search = { "read" },
				users = { "read" },
				files = { "read", "write" },
				reactions = { "write" },
				messages = { "write" },
			}
			local readOnly = {
				"channels:read",
				"channels:history",
				"groups:read",
				"groups:history",
				"im:read",
				"im:history",
				"mpim:read",
				"mpim:history",
				"users:read",
				"search:read",
				"files:read",
			}
			local readWrite = m.concat(readOnly, { "chat:write", "files:write", "im:write", "mpim:write", "reactions:write" })
			local defaults, top = { reactions = "none", messages = "none" }, {}
			for row, levels in rows do
				defaults[row] = defaults[row] or "read"
				top[row] = levels[#levels]
			end
			local cases = { { levels = defaults, scopes = readOnly }, { access = top, levels = top, scopes = readWrite } }
			for row, levels in rows do
				for _, level in levels do
					local only = {}
					for name in rows do
						only[name] = "none"
					end
					only[row] = level
					table.insert(cases, { access = only, levels = only })
				end
			end
			local publisher = { client_id = "fixture-client", client_secret = "fixture-secret" }
			for _, case in cases do
				local parts = {}
				for row, level in case.levels do
					table.insert(parts, row .. "=" .. level)
				end
				table.sort(parts)
				local label = table.concat(parts, " ")
				local scopes, allowed, blocked, open, closed, names, seen = {}, {}, {}, {}, {}, { "getProfile" }, {}
				for _, gate in gates do
					local on = rank[case.levels[gate.row]] >= rank[gate.level]
					if on then
						scopes = m.concat(scopes, gate.scopes)
						for _, name in gate.exports do
							if not seen[name] then
								seen[name] = true
								table.insert(names, name)
							end
						end
					end
					for _, route in gate.routes or {} do
						table.insert(if on then allowed else blocked, route)
					end
					for _, route in gate.unauthenticated or {} do
						table.insert(if on then open else closed, route)
					end
				end
				table.sort(names)
				if case.scopes and not m.equal(scopes, case.scopes) then
					m.fail("%s expected scopes do not reproduce the v1 set", label)
				end
				local r, err = m.resolve(publisher, {}, nil, "oauth", case.access)
				assert(not err, tostring(err))
				if not m.equal(r.Scopes, scopes) then
					m.fail("access=%s scopes %s", label, r.Scopes)
				end
				r.Context.Auth["oauth"].access_token = "xoxp-fixture"
				m.routes(r, "Bearer xoxp-fixture", true, m.concat(base, allowed))
				m.routes(r, "Bearer xoxp-fixture", false, m.concat(blocked, denied))
				m.routes(r, "", true, open)
				m.routes(r, "", false, closed)
				local result, exportErr = m.exports({}, "oauth", scopes, nil, case.access)
				assert(result and not exportErr, tostring(exportErr))
				if not (result.type == "result" and m.equal(result.exports, names)) then
					m.fail("access=%s exports %s", label, result.exports)
				end
			end
		end
	end,
}
