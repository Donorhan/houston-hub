return {
	contract = function(m)
		local google = {client_id = "google-client", client_secret = "google-secret"}
		local publisher = table.clone(google)
		publisher.composio_auth_config_id = "ac_fixture"
		publisher.composio_api_key = "fixture-secret"
		for _, field in {"composio_api_key", "composio_auth_config_id"} do
			local incomplete = table.clone(publisher)
			incomplete[field] = nil
			local _, err = m.resolve(incomplete, {}, nil, "composio")
			assert(err, "Incomplete Composio settings must require " .. field)
		end
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
		local api = "https://www.googleapis.com/drive/v3"
		local upload = "https://www.googleapis.com/upload/drive/v3"
		for _, access in {"read", "write"} do
			local r, err = m.resolve(publisher, {}, nil, "composio", {data = access})
			assert(r and not err, tostring(err))
			local reads = {"GET " .. api .. "/about?fields=user", "GET " .. api .. "/files?q=trashed%3Dfalse", "GET " .. api .. "/files/f1?alt=media", "GET " .. api .. "/files/f1/export?mimeType=text%2Fplain", "GET " .. api .. "/drives"}
			m.routes(r, "", true, reads)
			m.rejectOverrides(r, reads)
			m.routes(r, "", access == "write", {"POST " .. api .. "/files", "PATCH " .. api .. "/files/f1", "DELETE " .. api .. "/files/f1/permissions/p1", "POST " .. upload .. "/files?uploadType=resumable", "PUT " .. upload .. "/files?uploadType=resumable&upload_id=xyz"})
			m.refused(r, "", {"POST https://backend.composio.dev/api/v3.1/tools/execute/proxy", "GET https://www.googleapis.com/gmail/v1/users/me/profile", "POST " .. api .. "/drives"})
		end
	end,
}
