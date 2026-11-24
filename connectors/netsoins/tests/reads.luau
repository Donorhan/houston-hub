return {
	scenario = {publisher = {}, config = {host = "Ehpad-Test.NETSoins.org"}, auth_method = "key", auth_config = {token = "fixture-netsoins-key"}},
	configure = function()
		requests = {}
		payload = "{}"
		http = {request = function(req)
			table.insert(requests, req)
			assert(req.method == "GET" and req.body == nil, "NETSoins reads must be bodiless GETs")
			assert(req.headers.Authorization == nil, "credentials must remain in the proxy")
			assert(req.headers.Accept[1] == "application/json")
			assert(not string.find(req.url, "[?&]key=") and not string.find(req.url, "[?&]type="),
				"the key and access type are added by the proxy")
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(payload)})
		end}
	end,
	run = function(netsoins)
		local API = "https://ehpad-test.netsoins.org/webservice.php/teranga/"
		local STAFF = "teranga://ehpad-test.netsoins.org/Personnel#395214.18b3f92f1c"
		local function last() return requests[#requests].url end
		local function fields(href)
			return (string.gsub(string.match(href, "[?&]fields=([^&]*)"), "%%2C", ","))
		end

		local names = {}
		for name in netsoins do
			if name ~= "help" then table.insert(names, name) end
		end
		table.sort(names)
		assert(table.concat(names, ",") == "listCategorieProfessionnelle,listPersonnel", table.concat(names, ","))
		assert(#requests == 0, "initialization reached NETSoins")

		payload = '{"Personnel":[{"Uri":"' .. STAFF .. '","Nom":"Martin","Prenom":"Lea","Actif":"1","RPPS":"10101010101",'
			.. '"CategorieProfessionnelle":{"Uri":"teranga://ehpad-test.netsoins.org/CategorieProfessionnelle#3.ab","Libelle":"Infirmier/ère","ResidentsSuivis":[{"Uri":"teranga://ehpad-test.netsoins.org/Resident#1.a"}]},'
			.. '"PersonnelTypeAutorisations":[{"Libelle":"Soins"},{"Uri":"teranga://ehpad-test.netsoins.org/ResidentReferent#1.a","Libelle":"Mme Dupont"},'
			.. '{"Uri":"teranga://ehpad-test.netsoins.org/PersonnelTypeAutorisation#2.b","Libelle":{"Nom":"Dupont"}}],"Organisme":{},"DateNaissance":"1984-03-02T00:00:00.0000",'
			.. '"ResidentReferent":[{"Uri":"teranga://ehpad-test.netsoins.org/Resident#1.a","ResidentPathologie":[]}]}],"WS-Code":0}'
		local staff = netsoins.listPersonnel()
		-- Without fields, every documented staff field is requested, and only those come back.
		assert(string.match(last(), "^" .. string.gsub(API, "%p", "%%%0") .. "Personnel%?fields=[^&]+&output=json$"), last())
		local requested = fields(last())
		assert(string.find(requested, "^Uri,Actif,IdentifiantAdministratif,Login,") and string.find(requested, ",DerniereConnexion,Langue,Commentaire$"), requested)
		assert(not string.find(requested, "Resident", 1, true), requested)
		local lea = staff.Personnel[1]
		assert(staff["WS-Code"] == 0 and lea.Nom == "Martin" and lea.Actif == "1" and lea.RPPS == "10101010101")
		assert(lea.CategorieProfessionnelle.Libelle == "Infirmier/ère" and lea.PersonnelTypeAutorisations[1].Libelle == "Soins")
		assert(lea.ResidentReferent == nil, "an undocumented relation reached the caller")
		assert(lea.CategorieProfessionnelle.ResidentsSuivis == nil and lea.CategorieProfessionnelle.Uri ~= nil, "a linked object kept more than its Uri and Libelle")
		local profiles = lea.PersonnelTypeAutorisations
		assert(#profiles == 2 and profiles[1].Libelle == "Soins" and profiles[2].Libelle == nil and profiles[2].Uri ~= nil,
			"a resident link or a nested Libelle reached the caller: " .. json.encode(profiles))
		assert(type(lea.Organisme) == "table" and next(lea.Organisme) == nil)

		local opts = {statut_actif = "tous", statut_archive = "tous", fields = {"Uri", "Nom", "Prenom"}, Uri = STAFF}
		netsoins.listPersonnel(opts)
		assert(last() == API .. "Personnel?Uri=teranga%3A%2F%2Fehpad-test.netsoins.org%2FPersonnel%23395214.18b3f92f1c"
			.. "&fields=Uri%2CNom%2CPrenom&output=json&statut_actif=tous&statut_archive=tous", last())
		assert(#opts.fields == 3 and opts.Uri == STAFF, "caller options were modified")

		payload = '{"Personnel":[{"Uri":"teranga://ehpad_test/Personnel#395214-a_b","Nom":"Martin"}],"WS-Code":0}'
		assert(netsoins.listPersonnel({Uri = "teranga://ehpad_test/Personnel#395214-a_b"}).Personnel[1].Nom == "Martin")
		assert(string.find(last(), "Uri=teranga%3A%2F%2Fehpad_test%2FPersonnel%23395214-a_b", 1, true), last())

		payload = '{"Personnel":null,"WS-Code":0}'
		local null = netsoins.listPersonnel()
		assert(json.encode(null.Personnel) == "[]", json.encode(null))

		payload = '{"Personnel":[],"WS-Code":"0"}'
		local empty = netsoins.listPersonnel({statut_actif = "tous"})
		assert(json.encode(empty.Personnel) == "[]" and empty["WS-Code"] == "0", json.encode(empty))

		payload = '{"WS-Code":0}'
		local omitted = netsoins.listCategorieProfessionnelle()
		assert(last() == API .. "CategorieProfessionnelle?fields=Uri%2CLibelle%2CActif&output=json", last())
		assert(json.encode(omitted.CategorieProfessionnelle) == "[]", json.encode(omitted))

		payload = '{"CategorieProfessionnelle":[{"Uri":"teranga://ehpad-test.netsoins.org/CategorieProfessionnelle#3.ab","Libelle":"Infirmier/ère"},'
			.. '{"Uri":"teranga://ehpad-test.netsoins.org/CategorieProfessionnelle#9.cd","Libelle":"Direction","Code":"DIR"}],"WS-Code":0}'
		local categories = netsoins.listCategorieProfessionnelle({fields = {"Libelle"}})
		assert(last() == API .. "CategorieProfessionnelle?fields=Libelle%2CUri&output=json", last())
		local direction = categories.CategorieProfessionnelle[2]
		assert(#categories.CategorieProfessionnelle == 2 and direction.Libelle == "Direction" and direction.Code == nil and direction.Uri == nil)
		assert(#requests == 7, "each call makes one request")
	end,
}
