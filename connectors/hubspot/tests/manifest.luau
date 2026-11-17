local API = "https://api.hubapi.com"
local OBJECTS = API .. "/crm/objects/2026-09/"
-- Each access row and the object types it covers.
local ROWS = {
	contacts = {"contacts"}, companies = {"companies"}, deals = {"deals"}, tickets = {"tickets"},
	engagements = {"notes", "tasks", "calls", "meetings", "emails"},
}
local RANK = {none = 0, read = 1, write = 2}
-- The OAuth scopes of the schema version 1 read-only and read-write choices, which the default
-- levels and every row at write must request unchanged.
local READ_SCOPES = {
	"oauth", "crm.objects.contacts.read", "crm.objects.companies.read", "crm.objects.deals.read",
	"crm.objects.tickets.read", "crm.objects.owners.read", "crm.schemas.contacts.read", "crm.schemas.companies.read",
	"crm.schemas.deals.read", "crm.schemas.tickets.read", "sales-email-read",
}
local WRITE_SCOPES = {"crm.objects.contacts.write", "crm.objects.companies.write", "crm.objects.deals.write", "crm.objects.tickets.write"}

local function reads(row: string): {string}
	local routes = {}
	for _, kind in ROWS[row] do
		table.insert(routes, "GET " .. OBJECTS .. kind .. "?limit=100&properties=hs_timestamp,hubspot_owner_id")
		table.insert(routes, "GET " .. OBJECTS .. kind .. "/101")
		table.insert(routes, "GET " .. OBJECTS .. kind .. "/sku%3A123?idProperty=sku")
		table.insert(routes, "GET " .. OBJECTS .. kind .. "/101/associations/contacts?limit=500&after=x1")
		table.insert(routes, "POST " .. OBJECTS .. kind .. "/search")
		table.insert(routes, "POST " .. OBJECTS .. kind .. "/batch/read?archived=true")
		table.insert(routes, "GET " .. API .. "/crm/properties/2026-09/" .. kind .. "?archived=true")
		table.insert(routes, "GET " .. API .. "/crm/properties/2026-09/" .. kind .. "/hs_timestamp")
	end
	if row == "deals" or row == "tickets" then
		table.insert(routes, "GET " .. API .. "/crm/pipelines/2026-09/" .. row)
		table.insert(routes, "GET " .. API .. "/crm/pipelines/2026-09/" .. row .. "/0")
	end
	return routes
end

local function writes(row: string): {string}
	local routes = {}
	for _, kind in ROWS[row] do
		table.insert(routes, "POST " .. OBJECTS .. kind)
		table.insert(routes, "PATCH " .. OBJECTS .. kind .. "/101?idProperty=email")
		table.insert(routes, "PATCH " .. OBJECTS .. kind .. "/sku%3A123?idProperty=sku")
		table.insert(routes, "PUT " .. OBJECTS .. kind .. "/101/associations/companies/512")
		table.insert(routes, "PUT " .. OBJECTS .. kind .. "/101/associations/default/companies/512")
		table.insert(routes, "DELETE " .. OBJECTS .. kind .. "/101/associations/companies/512")
	end
	return routes
end

return {
	contract = function(m)
		-- Association batch reads and labels name both object types in placeholders, and owners
		-- belong to no row, so they are available at every level.
		local base = {
			"POST " .. API .. "/crm/associations/2026-09/deals/companies/batch/read",
			"GET " .. API .. "/crm/associations/2026-09/contacts/companies/labels",
			"GET " .. API .. "/crm/owners/2026-09?email=ana%40example.com&limit=500",
			"GET " .. API .. "/crm/owners/2026-09/41629779?idProperty=userId",
		}
		-- The token never reaches HubSpot's OAuth endpoints (token exchange, introspection, revocation,
		-- or /oauth/v1/access-tokens, which echoes the token), account details, other hosts, record
		-- deletes, bulk writes, merges, schema administration, other object types or API versions.
		-- Some routes stay reachable although the connector never sends them. An {objectId} placeholder
		-- admits any one segment, and /crm/properties/2026-09/<type>/{propertyName} also admits
		-- "groups" (property groups); both are GET and expose nothing beyond the granted scopes. The
		-- {fromObjectType} and {toObjectType} placeholders of the association routes admit any object type,
		-- such as quotes: a manifest cannot constrain placeholder values, and listing every pair of the
		-- nine types would take about 500 paths. Luau bounds them to the nine types, and the token's scopes
		-- bound what HubSpot answers.
		local anyTypeReads = {
			"GET " .. API .. "/crm/associations/2026-09/contacts/quotes/labels",
			"POST " .. API .. "/crm/associations/2026-09/quotes/contacts/batch/read",
		}
		local contactsToAnyType = {"GET " .. OBJECTS .. "contacts/101/associations/quotes"}
		local contactsToAnyTypeWrites = {
			"PUT " .. OBJECTS .. "contacts/101/associations/quotes/7", "PUT " .. OBJECTS .. "contacts/101/associations/default/quotes/7",
			"DELETE " .. OBJECTS .. "contacts/101/associations/quotes/7",
		}
		local denied = {
			"POST " .. API .. "/oauth/2026-09/token", "POST " .. API .. "/oauth/v3/token", "POST " .. API .. "/oauth/v1/token",
			"GET " .. API .. "/oauth/v1/access-tokens/fixture-token", "GET " .. API .. "/oauth/v1/refresh-tokens/x",
			"DELETE " .. API .. "/oauth/v1/refresh-tokens/x", "POST " .. API .. "/oauth/2026-09/token/introspect",
			"POST " .. API .. "/oauth/2026-09/token/revoke", "POST " .. API .. "/oauth/v2/private-apps/get/access-token-info",
			"POST https://api.hubspot.com/oauth/2026-09/token", "GET https://api.hubspot.com/crm/owners/2026-09",
			"GET https://api.hubapi.com.evil.test/crm/owners/2026-09", "GET https://api-eu1.hubapi.com/crm/owners/2026-09",
			"GET https://app.hubspot.com/oauth/authorize", "GET " .. API .. "/account-info/2026-09/details",
			"DELETE " .. OBJECTS .. "contacts/101", "POST " .. OBJECTS .. "contacts/batch/create",
			"POST " .. OBJECTS .. "contacts/batch/update", "POST " .. OBJECTS .. "contacts/batch/upsert",
			"POST " .. OBJECTS .. "contacts/batch/archive", "POST " .. OBJECTS .. "contacts/merge",
			"POST " .. OBJECTS .. "contacts/gdpr-delete", "PUT " .. OBJECTS .. "contacts/101",
			"POST " .. API .. "/crm/associations/2026-09/contacts/companies/batch/create",
			"POST " .. API .. "/crm/associations/2026-09/contacts/companies/batch/archive",
			"POST " .. API .. "/crm/associations/2026-09/contacts/companies/batch/associate/default",
			"POST " .. API .. "/crm/associations/2026-09/contacts/companies/labels",
			"DELETE " .. API .. "/crm/associations/2026-09/contacts/companies/labels/36",
			"GET " .. API .. "/crm/associations/2026-09/definitions/configurations/all",
			"POST " .. API .. "/crm/pipelines/2026-09/deals", "DELETE " .. API .. "/crm/pipelines/2026-09/deals/default",
			"PATCH " .. API .. "/crm/pipelines/2026-09/deals/default", "GET " .. API .. "/crm/pipelines/2026-09/deals/default/audit",
			"POST " .. API .. "/crm/properties/2026-09/contacts", "PATCH " .. API .. "/crm/properties/2026-09/contacts/email",
			"DELETE " .. API .. "/crm/properties/2026-09/contacts/email",
			"GET " .. OBJECTS .. "products", "GET " .. OBJECTS .. "users", "GET " .. OBJECTS .. "2-1234",
			"POST " .. OBJECTS .. "products", "GET " .. API .. "/crm/objects/v3/contacts", "GET " .. API .. "/crm/v3/objects/contacts",
			"GET " .. API .. "/crm/objects/2026-03/contacts", "GET " .. API .. "/crm/pipelines/2026-09/orders",
			"GET " .. OBJECTS .. "contacts/%2e%2e/users", "GET " .. OBJECTS .. "contacts/101/../../users",
			"GET " .. OBJECTS .. "contacts/101%2Fassociations/companies",
		}
		-- The default levels, every row at write, every row at none, then each row alone at write.
		local cases: {{[string]: string}} = {
			{},
			{contacts = "write", companies = "write", deals = "write", tickets = "write", engagements = "write"},
			{contacts = "none", companies = "none", deals = "none", tickets = "none", engagements = "none"},
		}
		for row in ROWS do
			local access = {contacts = "none", companies = "none", deals = "none", tickets = "none", engagements = "none"}
			access[row] = "write"
			table.insert(cases, access)
		end
		local publisher = {client_id = "publisher-client", client_secret = "publisher-secret"}
		for index, access in cases do
			local function rank(row: string): number return RANK[access[row] or "read"] end
			local scopes = {"oauth", "crm.objects.owners.read", "sales-email-read"}
			for row in ROWS do
				if row == "engagements" then continue end
				if rank(row) >= 1 then table.insert(scopes, "crm.objects." .. row .. ".read"); table.insert(scopes, "crm.schemas." .. row .. ".read") end
				if rank(row) == 2 then table.insert(scopes, "crm.objects." .. row .. ".write") end
			end
			if index == 1 then m.sortedEqual(m.concat(READ_SCOPES), scopes) end
			if index == 2 then m.sortedEqual(m.concat(READ_SCOPES, WRITE_SCOPES), scopes) end
			-- A manual token follows the same proxy rules, so the default and full levels cover it.
			for _, method in if index <= 2 then {"oauth", "token"} else {"oauth"} do
				local r, err = m.resolve(if method == "oauth" then publisher else nil, {},
					if method == "token" then {token = "fixture-token"} else nil, method, access)
				assert(r and not err, tostring(err))
				if method == "oauth" then
					m.sortedEqual(m.concat(scopes), m.concat(r.Scopes))
					r.Context.Auth.oauth.access_token = "fixture-token"
				else
					assert(m.count(r.Scopes) == 0, "a manual token requests no scopes")
				end
				m.routes(r, "Bearer fixture-token", true, m.concat(base, anyTypeReads))
				for row in ROWS do
					m.routes(r, "Bearer fixture-token", rank(row) >= 1, reads(row))
					m.routes(r, "Bearer fixture-token", rank(row) == 2, writes(row))
					if index == 2 and method == "oauth" then m.rejectOverrides(r, m.concat(reads(row), writes(row))) end
				end
				if index == 2 and method == "oauth" then m.rejectOverrides(r, base) end
				m.routes(r, "Bearer fixture-token", rank("contacts") >= 1, contactsToAnyType)
				m.routes(r, "Bearer fixture-token", rank("contacts") == 2, contactsToAnyTypeWrites)
				m.routes(r, "Bearer fixture-token", false, denied)
			end
		end
		local result, err = m.exports({}, "token", nil, nil, cases[3])
		assert(result and not err, tostring(err))
		assert(result.type == "result" and m.equal(result.exports, {"getOwner", "listOwners"}), "every row at none keeps only owners")
		assert(string.find(result.help, "This connection reads no records: only owners are available.", 1, true), result.help)
		result, err = m.exports({}, "token", nil, nil, {contacts = "write", companies = "none", deals = "read", tickets = "none", engagements = "none"})
		assert(result and not err and result.type == "result", tostring(err))
		assert(string.find(result.help, "objectType is one of contacts, deals; writes take contacts.", 1, true), result.help)
	end,
}
