return {
	scenario = {publisher = {}, access = {code = "none", conversations = "write", actions = "none", organizations = "none"}, config = {},
		auth_method = "token", auth_config = {token = "fixture-token"}},
	configure = function()
		requests = {}
		http = {request = function(req)
			table.insert(requests, req)
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader('{"number":3}')})
		end}
	end,
	run = function(github)
		assert(github.createIssue ~= nil and github.getContent == nil and github.listPullFiles == nil and github.mergePull == nil,
			"issues and pull requests without code exported the wrong functions")
		assert(github.getPull({owner = "o", repo = "r", pull_number = 3}).number == 3)
		local ok, err = pcall(function() github.getPull({owner = "o", repo = "r", pull_number = 3, format = "diff"}) end)
		assert(not ok and string.find(tostring(err), "format needs Code read access", 1, true), tostring(err))
		assert(#requests == 1, "a pull request diff reached GitHub without Code access")
	end,
}
