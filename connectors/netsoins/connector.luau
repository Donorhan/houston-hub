-- NETSoins webservice (/webservice.php/teranga), read-only staff and reference data. Arguments and results keep NETSoins' native field names.
type Options = {[string]: any}
type Resource = {name: string, fields: {string}, allowed: {[string]: boolean}}

local API = "https://" .. string.lower(config.host) .. "/webservice.php/teranga/"
local MAX_BODY = 8 * 1024 * 1024
local STATUS = "^[%a_]+$"

-- The webservice also serves resident and care records. Only these fields of these two
-- resources reach callers, every record must carry its own resource's Uri, and linked
-- objects keep only their Uri and Libelle, so a relation cannot bring health data along.
local function resource(name: string, fields: {string}): Resource
	local allowed: {[string]: boolean} = {}
	for _, field in fields do allowed[field] = true end
	return table.freeze({name = name, fields = table.freeze(fields), allowed = table.freeze(allowed)})
end
local PERSONNEL = resource("Personnel", {
	"Uri", "Actif", "IdentifiantAdministratif", "Login", "RPPS", "Adeli", "IdentifiantNational",
	"Civilite", "Genre", "Nom", "NomJeuneFille", "NomReligion", "Prenom", "DateNaissance",
	"VilleNaissance", "CodePostalNaissance", "IdentifiantDepartementNaissance", "IdentifiantPaysNaissance",
	"Adresse", "CodePostal", "Ville", "IdentifiantDepartement", "IdentifiantPays",
	"TelephoneFixe", "AutreTelephoneFixe", "TelephoneProfessionnel", "TelephoneMobile", "AutreTelephoneMobile",
	"TelephoneVacances", "Mail", "MailMSSante", "Fax", "Organisme", "CategorieProfessionnelle",
	"PersonnelTypeAutorisations", "AccesExterieur", "DateLimiteAcces", "DerniereConnexion", "Langue", "Commentaire",
})
local CATEGORIES = resource("CategorieProfessionnelle", {"Uri", "Libelle", "Actif"})

local help = {
	text = [[NETSoins staff accounts and their job categories for one facility (établissement), read-only.
Each call is one GET on the facility's NETSoins webservice. It returns {<Resource> = {records...},
["WS-Code"] = 0} with NETSoins' French field names; the connector keeps only the documented staff and
category fields, and an omitted list comes back empty. No paging parameter is known: a call returns
every matching record, so pass fields to keep large lists small (a result above 8 MiB fails).
Each record has a Uri such as teranga://<instance>/Personnel#395214.18b3f92f1c; passing it back as Uri
is expected to select that one record. Linked records are nested objects reduced to their Uri and
Libelle, such as CategorieProfessionnelle = {Uri, Libelle}. Dates are ISO 8601 date-time strings, sometimes with
fractional seconds or a UTC offset. Actif is 1 or 0, possibly as a string.
Pass statut_actif = "tous" and statut_archive = "tous" to include inactive and archived records,
for example when reviewing who still has access; without them NETSoins applies its default
selection, which may leave them out.
Resident records, care plans and other health data are not available through this connection.
Connector calls return completed values: use them directly, without await.]],
	functions = {} :: {[string]: any},
}
local exports: {[string]: any} = {help = help}

-- Builds the query from closed option names; Houston adds the key and access type.
local function query(name: string, target: Resource, input: any): (string, boolean)
	if input ~= nil then assert(type(input) == "table", name .. " takes one options object") end
	local opts: Options = input or {}
	local parts: {string} = {"output=json"}
	local fields: {string} = target.fields
	for key, value in opts do
		if key == "statut_actif" or key == "statut_archive" then
			assert(type(value) == "string" and #value <= 32 and string.match(value, STATUS),
				key .. " must be a NETSoins status word such as tous")
			table.insert(parts, key .. "=" .. url.encode(value))
		elseif key == "fields" then
			assert(type(value) == "table" and #value > 0 and #value <= #target.fields, "fields must be a nonempty array of field names")
			fields = {}
			for index, field in value do
				assert(type(index) == "number" and type(field) == "string" and target.allowed[field],
					"fields can name only these " .. target.name .. " fields: " .. table.concat(target.fields, ", "))
				table.insert(fields, field)
			end
		elseif key == "Uri" then
			assert(type(value) == "string" and #value <= 256
				and string.match(value, "^teranga://[%w%.%-]+/" .. target.name .. "#[%w%.]+$"),
				"Uri must be a " .. target.name .. " record's Uri, such as teranga://<instance>/" .. target.name .. "#395214.18b3f92f1c")
			table.insert(parts, "Uri=" .. url.encode(value))
		else
			error(name .. " has no option " .. string.sub(tostring(key), 1, 64))
		end
	end
	-- Every record is checked by its Uri, so it is always requested.
	local asked = table.find(fields, "Uri") ~= nil
	if not asked then
		fields = table.clone(fields)
		table.insert(fields, "Uri")
	end
	table.insert(parts, "fields=" .. url.encode(table.concat(fields, ",")))
	table.sort(parts)
	return table.concat(parts, "&"), asked
end

local function fail(name: string, status: number, retryable: boolean, message: string): never
	return houston.fail({operation = name, layer = "upstream", upstream_status = status,
		retryable = retryable, message = message})
end

-- NETSoins reports its own errors in WS-* fields; keep a few of them, bounded.
local function wsMessage(value: {[string]: any}): string
	local details: {string} = {}
	for key, item in value do
		if type(key) == "string" and string.sub(key, 1, 3) == "WS-" and (type(item) == "string" or type(item) == "number") then
			table.insert(details, string.sub(key, 1, 40) .. ": " .. string.sub(tostring(item), 1, 300))
		end
	end
	table.sort(details)
	return string.sub(table.concat(details, "; ", 1, math.min(#details, 6)), 1, 1000)
end

local function failure(name: string, response: HttpResponse): never
	local status = response.statusCode
	local raw = await(response.body:readPrefix(16 * 1024))
	local message = "NETSoins HTTP " .. tostring(status)
	local ok, value = pcall(json.decode, raw)
	local title = string.match(raw, "<title>%s*(.-)%s*</title>")
	if ok and type(value) == "table" and wsMessage(value) ~= "" then
		message ..= ": " .. wsMessage(value)
	elseif title then
		message ..= ": " .. string.sub(title, 1, 200)
	end
	if status == 401 or (status == 403 and not string.find(raw, "Cloudflare", 1, true)) then
		message ..= ". Check the API key and access type Orisha gave for this facility"
	elseif status == 403 then
		message ..= ". A firewall in front of NETSoins refused Houston's request; ask Orisha whether it blocks API clients"
	elseif status == 404 then
		message ..= ". Check the connection's NETSoins domain: the webservice must answer at " .. API
	end
	local retry = response.headers["retry-after"]
	if retry and retry[1] then message ..= "; Retry-After: " .. string.sub(retry[1], 1, 40) end
	return fail(name, status, status == 429 or status >= 500, message)
end

-- Linked objects, alone or in arrays, keep only the Uri and Libelle that name them.
local function linked(value: any): any
	if type(value) ~= "table" then return value end
	if value[1] ~= nil or next(value) == nil then
		local items: {any} = json.decode("[]")
		for _, item in value do table.insert(items, linked(item)) end
		return items
	end
	return {Uri = value.Uri, Libelle = value.Libelle}
end

local function list(name: string, target: Resource, input: any): Options
	local search, keepUri = query(name, target, input)
	local href = API .. target.name .. "?" .. search
	local response = await(http.request({method = "GET", url = href, headers = {Accept = {"application/json"}}}))
	if response.statusCode < 200 or response.statusCode >= 300 then failure(name, response) end
	local read, raw: any = pcall(function() return await(response.body:readAll(MAX_BODY)) end)
	if not read then
		if type(raw) ~= "table" or raw.code ~= "limit_exceeded" then error(raw, 0) end
		fail(name, response.statusCode, false, "NETSoins' answer exceeds Houston's 8 MiB limit; pass fields to return fewer fields")
	end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" or not string.match(raw, "^%s*{") then
		fail(name, response.statusCode, false, "NETSoins returned a response that is not a JSON object; check the connection's NETSoins domain")
	end
	local code = value["WS-Code"]
	if code ~= nil and tonumber(code) ~= 0 then
		fail(name, response.statusCode, false, "NETSoins refused the request: " .. wsMessage(value))
	end
	local records = value[target.name] or {}
	assert(type(records) == "table", "NETSoins returned an invalid " .. target.name .. " list")
	local kept: {Options} = json.decode("[]")
	for index, record in records do
		assert(type(index) == "number" and type(record) == "table", "NETSoins returned an invalid " .. target.name .. " list")
		local uri = record.Uri
		if not (type(uri) == "string" and string.match(uri, "^teranga://[^/]+/" .. target.name .. "#")) then
			fail(name, response.statusCode, false, "NETSoins returned a record that is not a " .. target.name .. " record; nothing was returned")
		end
		local copy: Options = {}
		for field, item in record do
			if target.allowed[field] and (field ~= "Uri" or keepUri) then copy[field] = linked(item) end
		end
		table.insert(kept, copy)
	end
	return {[target.name] = kept, ["WS-Code"] = code}
end

local READ = {readOnlyHint = true, openWorldHint = true}
local STATUS_SCHEMA = {type = "string", pattern = "^[A-Za-z_]+$", maxLength = 32,
	description = "tous includes inactive (or archived) records; omit for NETSoins' default selection."}
local function schemas(target: Resource, example: Options): (Options, Options)
	local input = {
		type = "object",
		properties = {
			statut_actif = STATUS_SCHEMA,
			statut_archive = STATUS_SCHEMA,
			fields = {type = "array", minItems = 1, maxItems = #target.fields, items = {enum = target.fields},
				description = "Return only these fields of each record."},
			Uri = {type = "string", maxLength = 256, pattern = "^teranga://[A-Za-z0-9.-]+/" .. target.name .. "#[A-Za-z0-9.]+$",
				description = "Return only the record with this Uri."},
		},
		additionalProperties = false,
		examples = {example},
	}
	local output = {
		type = "object",
		properties = {
			[target.name] = {type = "array", items = {type = "object"}},
			["WS-Code"] = {type = {"integer", "string"}},
		},
		required = {target.name},
	}
	return input, output
end

local personnelInput, personnelOutput = schemas(PERSONNEL,
	{statut_actif = "tous", fields = {"Uri", "Nom", "Prenom", "Actif", "CategorieProfessionnelle", "DerniereConnexion"}})
help.functions.listPersonnel = {
	description = [[Staff accounts with access to NETSoins: {Personnel = {...}, ["WS-Code"] = 0}. A record holds
Uri, IdentifiantAdministratif, Login, Actif, identity (Civilite, Genre, Nom, NomJeuneFille, NomReligion,
Prenom, DateNaissance and birth place), contact details (Adresse, CodePostal, Ville, telephones, Mail,
MailMSSante, Fax), professional identifiers (RPPS, Adeli, IdentifiantNational), Organisme,
CategorieProfessionnelle {Uri, Libelle}, PersonnelTypeAutorisations (its permission profiles),
AccesExterieur, DateLimiteAcces, DerniereConnexion, Langue and Commentaire, as far as NETSoins fills them.]],
	inputSchema = personnelInput,
	outputSchema = personnelOutput,
	annotations = READ,
}
function exports.listPersonnel(input: Options?): Options
	return list("listPersonnel", PERSONNEL, input)
end

local categoryInput, categoryOutput = schemas(CATEGORIES, {statut_actif = "tous"})
help.functions.listCategorieProfessionnelle = {
	description = [[The facility's job categories: {CategorieProfessionnelle = {{Uri, Libelle, Actif}}, ["WS-Code"] = 0}.
A staff record's CategorieProfessionnelle.Uri points to one of them.]],
	inputSchema = categoryInput,
	outputSchema = categoryOutput,
	annotations = READ,
}
function exports.listCategorieProfessionnelle(input: Options?): Options
	return list("listCategorieProfessionnelle", CATEGORIES, input)
end

return exports
