return {
	contract = function(m)
		local publisher = {composio_auth_config_id = "ac_fixture", composio_api_key = "fixture-secret"}
		for _, field in {"composio_api_key", "composio_auth_config_id"} do
			local incomplete = table.clone(publisher)
			incomplete[field] = nil
			local _, err = m.resolve(incomplete, {}, nil, "composio")
			assert(err, "Incomplete Composio settings must require " .. field)
		end
		local direct, directError = m.resolve({client_id = "google-client", client_secret = "google-secret"}, {}, nil, "oauth")
		assert(direct and not directError, "Direct Google sign-in must work without Composio settings")
		local google = {client_id = "google-client", client_secret = "google-secret"}
		for _, settings in {{}, {composio_auth_config_id = "", composio_api_key = ""}, {composio_auth_config_id = "ac_fixture"}, {composio_api_key = "fixture-secret"}, publisher} do
			local values = table.clone(google)
			for key, value in settings do
				values[key] = value
			end
			local form, err = m.draft(values, {}, nil, "oauth")
			assert(form and not err, tostring(err))
			for _, method in form.Methods do
				local offered = method.key == "oauth" or settings == publisher
				assert(method.eligible == offered and method.available == offered, "Sign-in choices must reflect complete publisher settings")
			end
			local resolved, resolveError = m.resolve(values, {}, nil, "oauth")
			assert(resolved and not resolveError, "Optional Composio settings must not prevent Google sign-in")
		end
		local api = "https://gmail.googleapis.com/gmail/v1/users/me"
		local upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me"
		for _, access in {
			{messages = "read", drafts = "none", sending = "none"}, {messages = "none", drafts = "manage", sending = "none"},
			{messages = "read", drafts = "create", sending = "none"}, {messages = "organize", drafts = "manage", sending = "send"},
		} do
			local r, err = m.resolve(publisher, {}, nil, "composio", access)
			assert(r and not err, tostring(err))
			m.routes(r, "", access.messages ~= "none", {"GET " .. api .. "/profile", "GET " .. api .. "/messages?q=is%3Aunread"})
			m.routes(r, "", access.drafts ~= "none", {"POST " .. upload .. "/drafts?uploadType=multipart"})
			m.routes(r, "", access.drafts == "manage", {"GET " .. api .. "/drafts", "GET " .. api .. "/drafts/d1", "PUT " .. upload .. "/drafts/d1?uploadType=multipart", "DELETE " .. api .. "/drafts/d1"})
			m.routes(r, "", access.messages == "organize", {"POST " .. api .. "/messages/m1/modify", "POST " .. api .. "/labels"})
			m.routes(r, "", access.sending == "send", {"POST " .. upload .. "/messages/send?uploadType=multipart"})
			if access.messages ~= "none" then m.rejectOverrides(r, {"GET " .. api .. "/messages/m1"}) end
			m.refused(r, "", {
				"POST https://backend.composio.dev/api/v3.1/tools/execute/proxy", "GET https://gmail.googleapis.com/gmail/v1/users/someone@example.com/profile",
				"GET https://www.googleapis.com/oauth2/v2/userinfo", "POST " .. api .. "/drafts/send", "POST " .. api .. "/messages/m1/trash", "GET " .. api .. "/settings/sendAs",
			})
		end
	end,
}
