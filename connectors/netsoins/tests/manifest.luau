return {
	contract = function(m)
		local api = "https://ehpad-test.netsoins.org/webservice.php/teranga/"
		-- Each allowed route carries the facility's key and access type, replacing a caller's, and drops other credentials.
		local function keyed(r, kind)
			for _, route in {
				"Personnel?output=json",
				"Personnel?fields=Nom%2CPrenom&output=json&statut_actif=tous&Uri=teranga%3A%2F%2Fehpad-test.netsoins.org%2FPersonnel%23395214.18b3f92f1c",
				"CategorieProfessionnelle?output=json",
				"Personnel?output=json&key=forged&type=forged",
				"Personnel?output=json&key%5B%5D=forged&type%5B%5D=forged&%20type=forged",
			} do
				local recipe, problem = m.recipe(r, "GET", api .. route)
				if problem ~= nil then m.fail("GET %s denied: %s", route, problem) end
				local prepared, bad = m.prepareUrl(recipe, r.Context)
				assert(not bad, tostring(bad))
				if string.match(prepared, "[?&]key=([^&]*)") ~= "synthetic+%2B%26key" or string.match(prepared, "[?&]type=([^&]*)") ~= kind
					or string.find(prepared, "forged", 1, true) then
					m.fail("query credentials not injected: %s", prepared)
				end
				m.rejectPreparedOverrides(recipe, r.Context, "GET " .. route)
				local headers, refused = m.prepare(recipe, r.Context, {
					Authorization = {"Bearer forged"}, Cookie = {"PHPSESSID=forged"}, Accept = {"application/json"},
				})
				if refused ~= nil or m.count(headers) ~= 1 or m.header(headers, "Accept") ~= "application/json" then
					m.fail("unsafe caller headers: %s %s", headers, refused)
				end
			end
		end
		local r, err = m.resolve(nil, {host = "ehpad-test.netsoins.org", type = "teranga"}, {token = "synthetic +&key"}, "key")
		assert(r and not err, tostring(err))
		keyed(r, "teranga")
		local default, problem = m.resolve(nil, {host = "Ehpad-Test.NETSoins.org"}, {token = "synthetic +&key"}, "key")
		assert(default and not problem, tostring(problem))
		keyed(default, "isiapp")

		-- Resident and care data, writes, other hosts and path tricks stay closed.
		m.routes(r, "", false, {
			"GET " .. api .. "Resident?output=json",
			"GET " .. api .. "ResidentContact?output=json",
			"GET " .. api .. "EtablissementChambre?output=json",
			"GET " .. api .. "EtablissementSousSecteur?output=json",
			"GET " .. api .. "Transmission?output=json",
			"GET " .. api .. "Personnel/12",
			"GET " .. api .. "Personnel/",
			"GET " .. api .. "personnel?output=json",
			"GET " .. api .. "Personnel/../Resident",
			"GET " .. api .. "Personnel%2F..%2FResident",
			"GET " .. api .. "%2e%2e/Resident",
			"POST " .. api .. "Personnel?input=json",
			"PUT " .. api .. "Personnel",
			"DELETE " .. api .. "Personnel",
			"POST " .. api .. "Transmission?input=json",
			"GET https://ehpad-test.netsoins.org/webservice.php/autre/Personnel",
			"GET https://ehpad-test.netsoins.org/index.php",
			"GET https://ehpad-test.netsoins.org.evil.example/webservice.php/teranga/Personnel",
			"GET https://other.netsoins.org/webservice.php/teranga/Personnel",
			"GET http://ehpad-test.netsoins.org/webservice.php/teranga/Personnel",
		})
		for _, host in {"", "https://ehpad-test.netsoins.org", "ehpad-test.netsoins.org/webservice.php", "*.netsoins.org"} do
			local _, refused = m.resolve(nil, {host = host}, {token = "synthetic"}, "key")
			if refused == nil then m.fail("accepted NETSoins domain %s", host) end
		end
	end,
}
