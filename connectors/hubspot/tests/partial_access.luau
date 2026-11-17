return {
	scenario = {publisher = {}, access = {contacts = "write", companies = "none", deals = "read", tickets = "none", engagements = "none"},
		config = {}, auth_method = "token", auth_config = {token = "fixture-token"}},
	configure = function()
		requests = {}
		http = {request = function(req)
			table.insert(requests, req)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"id":"1","results":[]}')})
		end}
	end,
	run = function(c)
		local OBJECTS = "https://api.hubapi.com/crm/objects/2026-09/"
		local names = {}
		for name in c do table.insert(names, name) end
		table.sort(names)
		assert(table.concat(names, ",") == "batchReadAssociations,batchReadObjects,createAssociation,createDefaultAssociation,createObject,deleteAssociation,"
			.. "getObject,getOwner,getPipeline,getProperty,listAssociationLabels,listAssociations,listObjects,listOwners,listPipelines,listProperties,"
			.. "searchObjects,updateObject", "partial access got " .. table.concat(names, ","))

		local function fails(expected: string, fn: (any) -> any, input: any)
			local before = #requests
			local ok, err = pcall(fn, input)
			assert(not ok and string.find(tostring(err), expected, 1, true), tostring(err))
			assert(#requests == before, "a refused call reached HubSpot")
		end
		fails("objectType must be one of contacts, deals", c.getObject, {objectType = "companies", objectId = "512"})
		fails("objectType must be one of contacts, deals", c.searchObjects, {objectType = "notes"})
		fails("associations[1] must be one of contacts, deals", c.listObjects, {objectType = "contacts", associations = {"tickets"}})
		fails("objectType must be one of deals", c.listPipelines, {objectType = "tickets"})
		fails("objectType must be one of contacts", c.createObject, {objectType = "deals", properties = {dealname = "Renewal"}})
		fails("objectType must be one of contacts", c.updateObject, {objectType = "deals", objectId = "9876", properties = {amount = "1"}})
		fails("toObjectType must be one of contacts, deals", c.createDefaultAssociation,
			{fromObjectType = "contacts", fromObjectId = "101", toObjectType = "companies", toObjectId = "512"})
		fails("objectType must be one of contacts", c.deleteAssociation, {objectType = "deals", objectId = "9876", toObjectType = "contacts", toObjectId = "101"})

		c.listPipelines({objectType = "deals"})
		c.createDefaultAssociation({fromObjectType = "contacts", fromObjectId = "101", toObjectType = "deals", toObjectId = "9876"})
		assert(#requests == 2 and requests[1].url == "https://api.hubapi.com/crm/pipelines/2026-09/deals"
			and requests[2].method == "PUT" and requests[2].url == OBJECTS .. "contacts/101/associations/default/deals/9876", requests[#requests].url)
	end,
}
