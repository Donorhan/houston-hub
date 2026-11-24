-- Only WS-Code (0 on success) is documented by known clients; the WS-Message bodies below are synthetic.
return {
	scenario = {publisher = {}, config = {host = "ehpad-test.netsoins.org", type = "teranga"}, auth_method = "key", auth_config = {token = "fixture-netsoins-key"}},
	configure = function()
		calls = 0
		status = 200
		payload = "{}"
		responseHeaders = {}
		http = {request = function(req)
			calls += 1
			return fixture.operation({statusCode = status, headers = responseHeaders, body = fixture.reader(payload)})
		end}
	end,
	run = function(netsoins)
		local RESIDENT = "teranga://ehpad-test.netsoins.org/Resident#351261.e3966f4a1f"
		local function rejected(fn, expected)
			local before = calls
			local ok, err = pcall(fn)
			assert(not ok and string.find(tostring(err), expected, 1, true), "wrong validation error: " .. tostring(err))
			assert(calls == before, "invalid input reached NETSoins")
		end
		rejected(function() netsoins.listPersonnel("tous") end, "takes one options object")
		rejected(function() netsoins.listPersonnel({key = "forged"}) end, "has no option key")
		rejected(function() netsoins.listPersonnel({type = "teranga"}) end, "has no option type")
		rejected(function() netsoins.listPersonnel({statut_actif = "tous&key=x"}) end, "statut_actif must be")
		rejected(function() netsoins.listPersonnel({statut_archive = 1}) end, "statut_archive must be")
		rejected(function() netsoins.listPersonnel({fields = {}}) end, "fields must be a nonempty array")
		rejected(function() netsoins.listPersonnel({fields = "Nom"}) end, "fields must be a nonempty array")
		rejected(function() netsoins.listPersonnel({fields = {"Nom", "ResidentReferent"}}) end, "fields can name only these Personnel fields")
		rejected(function() netsoins.listCategorieProfessionnelle({fields = {"Nom"}}) end, "fields can name only these CategorieProfessionnelle fields")
		rejected(function() netsoins.listPersonnel({Uri = RESIDENT}) end, "Uri must be a Personnel record's Uri")
		rejected(function() netsoins.listPersonnel({Uri = "teranga://ehpad-test.netsoins.org/Personnel#1&Uri=" .. RESIDENT}) end, "Uri must be")
		rejected(function() netsoins.listCategorieProfessionnelle({Uri = "teranga://ehpad-test.netsoins.org/Personnel#1.a"}) end, "Uri must be")
		rejected(function() netsoins.listCategorieProfessionnelle({Uri = ""}) end, "Uri must be")

		local function upstream(code, body, headers, expected)
			status, payload, responseHeaders = code, body, headers
			local before = calls
			local ok, err = pcall(function() netsoins.listPersonnel() end)
			for _, text in expected do
				assert(not ok and string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err))
			end
			assert(not string.find(tostring(err), "Pathologie", 1, true), "resident data reached an error")
			assert(calls == before + 1, "a failed read was retried")
		end
		upstream(401, '{"WS-Code":401,"WS-Message":"Cle invalide"}', {},
			{"HTTP 401", "WS-Message: Cle invalide", "Check the API key", '"retryable":false'})
		upstream(403, "<html><title>Forbidden</title></html>", {},
			{"HTTP 403", "Forbidden", "Check the API key", '"retryable":false'})
		upstream(403, "<!DOCTYPE html><html><head><title>Attention Required! | Cloudflare</title></head><body>Cloudflare</body></html>", {},
			{"HTTP 403", "Attention Required! | Cloudflare", "A firewall in front of NETSoins", '"retryable":false'})
		upstream(404, "<html><title>Not Found</title></html>", {},
			{"HTTP 404", "Not Found", "https://ehpad-test.netsoins.org/webservice.php/teranga/", '"retryable":false'})
		upstream(429, "", {["retry-after"] = {"30"}}, {"HTTP 429", "Retry-After: 30", '"retryable":true'})
		upstream(503, "<html>maintenance</html>", {}, {"HTTP 503", '"retryable":true'})
		upstream(200, '{"WS-Code":12}', {}, {"NETSoins refused the request: WS-Code: 12", '"retryable":false'})
		upstream(200, '{"WS-Code":12,"WS-Message":"' .. string.rep("x", 5000) .. '"}', {}, {"WS-Message: xxx"})
		upstream(200, "<html>Connexion</html>", {}, {"not a JSON object", '"retryable":false'})
		upstream(200, "[]", {}, {"not a JSON object"})
		upstream(200, '{"Personnel":"none","WS-Code":0}', {}, {"invalid Personnel list"})
		upstream(200, '{"Personnel":{"Uri":"x"},"WS-Code":0}', {}, {"invalid Personnel list"})
		upstream(200, '{"Personnel":[{"Nom":"Martin","DateNaissance":"1931-01-02T00:00:00"}],"WS-Code":0}', {},
			{"not a Personnel record; nothing was returned"})
		upstream(200, '{"Personnel":[{"Uri":"' .. RESIDENT .. '","ResidentPathologie":[{"Libelle":"Pathologie"}]}],"WS-Code":0}', {},
			{"not a Personnel record; nothing was returned", '"retryable":false'})

		status, payload = 200, '{"Personnel":[{"Uri":"teranga://ehpad-test.netsoins.org/Personnel#1.a","Nom":"Martin"},{"Uri":"teranga://ehpad-test.netsoins.org/Personnel#2.b","Nom":"Durand"}],"WS-Code":0}'
		local unfiltered, ignored = pcall(function() netsoins.listPersonnel({Uri = "teranga://ehpad-test.netsoins.org/Personnel#1.a"}) end)
		assert(not unfiltered and string.find(tostring(ignored), "other than the requested Uri", 1, true), tostring(ignored))

		status, payload = 200, '{"WS-Code":1,"WS-Message":"' .. string.rep("y", 5000) .. '"}'
		local ok, err = pcall(function() netsoins.listPersonnel() end)
		assert(not ok and #tostring(err) < 2000, "an oversized NETSoins error was not bounded")
	end,
}
