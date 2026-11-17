return {
	contract = function(m)
		local source = m.modules["connector.luau"]
		local set = assert(
			string.match(source, "local OPAQUE = table.freeze%(%{([^}]*)%}%)"),
			"missing opaque parameter set"
		)
		local opaque = {}
		for name in string.gmatch(set, "([%w_]+) = true") do
			opaque[name] = true
		end
		local want, got, free = {}, {}, {}
		for _, entry in m.endpoints() do
			local names = {}
			for name in string.gmatch(entry.path, "{([%w_]+)}") do
				if opaque[name] then
					table.insert(names, name)
				end
			end
			table.sort(names)
			table.insert(
				want,
				entry.method .. " api.github.com " .. entry.path .. " " .. table.concat(names, ",")
			)
		end
		for _, rule in m.raw.proxy do
			if not rule.action.headers.set or not rule.action.headers.set.Authorization then
				table.insert(free, rule)
				continue
			end
			local names = m.concat(rule.match.opaque_path_parameters or {})
			table.sort(names)
			for _, host in rule.match.host do
				for _, method in rule.match.method do
					for _, path in rule.match.path do
						table.insert(
							got,
							method .. " " .. host .. " " .. path .. " " .. table.concat(names, ",")
						)
					end
				end
			end
		end
		m.sortedEqual(want, got)
		-- Each download host travels without credentials and only with the row it serves.
		local downloads = {
			[m.accessGate("code:read")] = {
				"codeload.github.com",
				"release-assets.githubusercontent.com",
				"objects.githubusercontent.com",
				"objects-origin.githubusercontent.com",
				"github-releases.githubusercontent.com",
			},
			[m.accessGate("gists:read")] = { "gist.githubusercontent.com" },
			[m.accessGate("actions:read")] = { "*.actions.githubusercontent.com", "*.blob.core.windows.net" },
		}
		assert(#free == m.count(downloads), "download rules changed")
		for _, rule in free do
			assert(
				m.equal(rule.match.host, downloads[rule["if"]])
					and m.equal(rule.match.method, { "GET" })
					and m.equal(rule.action.headers.remove, { "Authorization" }),
				"download rule credentials, hosts or access changed"
			)
		end
	end,
}
