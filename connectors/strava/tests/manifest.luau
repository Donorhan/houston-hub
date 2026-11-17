local API = "https://www.strava.com/api/v3"
local PUBLISHER = {client_id = "fixture-client", client_secret = "fixture-client-secret"}
local READ_SCOPES = {"read", "read_all", "profile:read_all", "activity:read_all"}

return {
	contract = function(m)
		-- The publication owns the OAuth client; connections choose only their access.
		assert(m.publisherClient(m.raw.auth.oauth), "Strava OAuth client must belong to the publication")
		assert(m.raw.connections == "personal-only", "Strava data may be shown only to the athlete who connected it")
		for _, publisher in {{}, {client_id = "client"}, PUBLISHER} do
			local draft, err = m.draft(publisher, nil, nil, "")
			assert(not err, tostring(err))
			for _, field in draft.ConfigFields do
				if field.name ~= "access" then m.fail("connection form asks for %s", field.name) end
			end
			local available = m.count(publisher) == 2
			if m.count(draft.Methods) ~= 1 or draft.Methods[1].available ~= available then
				m.fail("publisher=%s methods=%s; available=%s", publisher, draft.Methods, available)
			end
		end
		local _, replaced = m.resolve(PUBLISHER, {client_id = "own-client", client_secret = "own-secret"}, nil, "oauth")
		assert(replaced ~= nil, "a connection replaced the publication's OAuth client")

		local reads = {
			"GET " .. API .. "/athlete", "GET " .. API .. "/athlete/zones",
			"GET " .. API .. "/athlete/activities?after=1767225600&per_page=200", "GET " .. API .. "/athlete/clubs?page=2",
			"GET " .. API .. "/athletes/134815/stats", "GET " .. API .. "/athletes/134815/routes",
			"GET " .. API .. "/activities/16532880011?include_all_efforts=true", "GET " .. API .. "/activities/16532880011/laps",
			"GET " .. API .. "/activities/16532880011/zones", "GET " .. API .. "/activities/16532880011/comments?after_cursor=abc123%2520",
			"GET " .. API .. "/activities/16532880011/kudos", "GET " .. API .. "/activities/16532880011/streams?keys=time%2Cwatts&key_by_type=true",
			"GET " .. API .. "/clubs/231407", "GET " .. API .. "/gear/b12345678", "GET " .. API .. "/routes/3344425285447071234",
			"GET " .. API .. "/routes/3344425285447071234/streams", "GET " .. API .. "/routes/3344425285447071234/export_gpx",
			"GET " .. API .. "/routes/3344425285447071234/export_tcx", "GET " .. API .. "/segments/starred", "GET " .. API .. "/segments/229781",
			"GET " .. API .. "/segments/229781/streams?keys=latlng&key_by_type=true", "GET " .. API .. "/segment_efforts?segment_id=229781",
			"GET " .. API .. "/segment_efforts/2922283800928553202", "GET " .. API .. "/segment_efforts/2922283800928553202/streams?keys=watts&key_by_type=true",
		}
		local writes = {
			"POST " .. API .. "/activities", "POST " .. API .. "/uploads", "GET " .. API .. "/uploads/15467223451",
			"PUT " .. API .. "/athlete", "PUT " .. API .. "/activities/16532880011", "PUT " .. API .. "/segments/229781/starred",
		}
		-- The token never reaches Strava's OAuth endpoints (exchange, revocation, deauthorization),
		-- webhook subscriptions (managed with the client secret), deletes, other hosts or API versions.
		local denied = {
			"POST https://www.strava.com/oauth/token", "POST " .. API .. "/oauth/token", "POST https://www.strava.com/oauth/revoke",
			"POST https://www.strava.com/oauth/deauthorize", "GET https://www.strava.com/oauth/authorize?client_id=1",
			"GET " .. API .. "/push_subscriptions", "POST " .. API .. "/push_subscriptions", "DELETE " .. API .. "/push_subscriptions/1",
			"DELETE " .. API .. "/activities/16532880011", "DELETE " .. API .. "/uploads/1", "PUT " .. API .. "/athlete/zones",
			"POST " .. API .. "/clubs/231407/join", "POST " .. API .. "/activities/16532880011/kudos",
			"GET " .. API .. "/athletes/134815", "GET " .. API .. "/athletes/134815/koms", "GET " .. API .. "/clubs/231407/members",
			"GET " .. API .. "/clubs/231407/activities", "GET https://www.strava.com/activities/16532880011/export_gpx",
			"GET https://www.strava.com/api/v4/athlete", "GET https://api-v3.strava.com/athlete", "GET https://api.strava.com/api/v3/athlete",
			"GET https://strava.com/api/v3/athlete", "GET https://www.strava.com.evil.test/api/v3/athlete",
			"GET " .. API .. "/activities/1%2F..%2F2", "GET " .. API .. "/activities/%2e%2e%2fathlete",
		}
		for _, access in {"read-only", "read-write"} do
			local r, err = m.resolve(PUBLISHER, {access = access}, nil, "oauth")
			assert(not err, tostring(err))
			if r.PublicConfig.access ~= access or m.count(r.PublicConfig) ~= 1 then m.fail("unexpected public settings: %s", r.PublicConfig) end
			local scopes = if access == "read-write" then m.concat(READ_SCOPES, {"profile:write", "activity:write"}) else READ_SCOPES
			if not m.equal(r.Scopes, scopes) then m.fail("access=%s scopes %s", access, r.Scopes) end
			r.Context.Auth.oauth.access_token = "fixture-token"
			m.routes(r, "Bearer fixture-token", true, reads)
			m.routes(r, "Bearer fixture-token", access == "read-write", writes)
			m.routes(r, "Bearer fixture-token", false, denied)
			m.rejectOverrides(r, {"GET " .. API .. "/athlete", "GET " .. API .. "/activities/16532880011"})
		end
	end,
}
