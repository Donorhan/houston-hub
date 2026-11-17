return {
	contract = function(m)
		for _, case in
			{
				{ scopes = {}, exports = {} },
				{ scopes = { "account_info.read" }, exports = { "getCurrentAccount", "getSpaceUsage" } },
				{
					scopes = { "files.metadata.read" },
					exports = {
						"getMetadata",
						"listFolder",
						"listFolderContinue",
						"listFolderGetLatestCursor",
						"listRevisions",
						"search",
						"searchContinue",
						"statFile",
					},
				},
				-- Rows gate exports even when the token holds broader scopes.
				{
					scopes = { "account_info.read", "files.metadata.read", "files.content.read", "file_requests.read", "file_requests.write", "sharing.read" },
					access = { files = "none", sharing = "none", file_requests = "write" },
					exports = {
						"createFileRequest",
						"deleteFileRequest",
						"getCurrentAccount",
						"getFileRequest",
						"getSpaceUsage",
						"listFileRequests",
						"listFileRequestsContinue",
						"updateFileRequest",
					},
				},
			}
		do
			local access = case.access or { files = "write", sharing = "write", file_requests = "write" }
			local result, err = m.exports({}, "oauth", case.scopes, nil, access)
			assert(result and not err, tostring(err))
			if #case.exports == 0 then
				assert(
					result.type == "error"
						and string.find(result.error, "configured bundle has no exports", 1, true),
					"empty grant exposed operations"
				)
			else
				assert(
					result.type == "result" and m.equal(result.exports, case.exports),
					"wrong configured exports"
				)
				local documented = {}
				for name in string.gmatch("\n" .. result.help, "\n([^%s%(]+)%(") do
					table.insert(documented, name)
				end
				assert(m.equal(documented, case.exports), "help does not match configured exports")
			end
		end
	end,
}
