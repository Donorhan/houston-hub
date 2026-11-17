return {
	contract = function(m)
		local api = "https://api.github.com"
		local publisher = { client_id = "Iv23liFixture", client_secret = "fixture-client-secret" }
		local rank, top = {}, {}
		for _, row in m.raw.access do
			rank[row.name] = {}
			for index, level in row.levels do
				rank[row.name][level.value] = index
			end
			top[row.name] = row.levels[#row.levels].value
		end
		local function allows(access, needs)
			for row, level in needs do
				if rank[row][access[row]] < rank[row][level] then
					return false
				end
			end
			return true
		end
		local function matrix(levels)
			local access = {}
			for row in rank do
				access[row] = levels[row] or "none"
			end
			return access
		end
		-- Each group names the access it needs; routes are relative to the API unless absolute.
		local groups = {
			{ needs = {}, routes = {
				"GET /user",
				"GET /users/octocat",
				"GET /user/repos",
				"GET /repos/o/r",
				"GET /repos/o/r/languages",
				"GET /repos/o/r/stargazers",
				"GET /rate_limit",
				"GET /search/repositories?q=x",
			} },
			{ needs = { code = "read" }, routes = {
				"GET /repos/o/r/branches/feature%2Fx",
				"GET /repos/o/r/contents/src%2Fmain.go?ref=release%2F1",
				"GET /repos/o/r/contents/test%2Ffolder%2525with%20percentage%23%2Findex.js",
				"GET /repos/o/r/branches/fix%2F100%25",
				"GET /repos/o/r/compare/main...feature%2Fx",
				"GET /repos/o/r/git/ref/heads%2Ffeature%2Fx",
				"GET /repos/o/r/git/trees/feature%2Fx",
				"GET /repos/o/r/releases/tags/app%2Fv1",
				"GET /repos/o/r/tarball/main",
				"GET /repos/o/r/tags",
				"GET /search/code?q=x",
				"GET /search/commits?q=x",
			} },
			{ needs = { code = "write" }, routes = {
				"PUT /repos/o/r/contents/docs%2Fa.md",
				"DELETE /repos/o/r/contents/docs%2Fa.md",
				"PATCH /repos/o/r/git/refs/heads%2Fx",
				"DELETE /repos/o/r/git/refs/heads%2Fx",
				"POST /repos/o/r/branches/old%2Fname/rename",
				"POST /repos/o/r/commits/c1/comments",
				"POST /repos/o/r/merges",
				"POST /repos/o/r/releases",
			} },
			{ needs = { conversations = "read" }, routes = {
				"GET /issues",
				"GET /repos/o/r/issues?state=open",
				"GET /repos/o/r/pulls/1",
				"GET /repos/o/r/pulls/comments/1",
				"GET /repos/o/r/collaborators",
				"GET /search/issues?q=x",
			} },
			{ needs = { conversations = "write" }, routes = {
				"POST /repos/o/r/issues",
				"PATCH /repos/o/r/pulls/1",
				"PATCH /repos/o/r/pulls/comments/1",
				"DELETE /repos/o/r/issues/1/labels/area%2Fui",
				"DELETE /repos/o/r/issues/1/labels/50%25%20done",
				"PATCH /repos/o/r/labels/100%25",
				"POST /repos/o/r/pulls/1/reviews",
			} },
			{ needs = { code = "read", conversations = "read" }, routes = {
				"GET /users/octocat/events",
				"GET /users/octocat/received_events",
				"GET /repos/o/r/events",
				"GET /repos/o/r/pulls/1/files",
				"GET /repos/o/r/pulls/1/commits",
				"GET /repos/o/r/commits/c1/pulls",
			} },
			{ needs = { code = "write", conversations = "write" }, routes = {
				"PUT /repos/o/r/pulls/1/merge",
				"PUT /repos/o/r/pulls/1/update-branch",
			} },
			{ needs = { actions = "read" }, routes = {
				"GET /repos/o/r/commits/feature%2Fx/check-runs",
				"GET /repos/o/r/commits/main/status",
				"GET /repos/o/r/actions/runs",
				"GET /repos/o/r/actions/jobs/1/logs",
			} },
			{ needs = { actions = "write" }, routes = {
				"POST /repos/o/r/actions/runs/1/cancel",
				"POST /repos/o/r/actions/workflows/ci.yml/dispatches",
				"POST /repos/o/r/statuses/c1",
			} },
			{ needs = { gists = "read" }, routes = { "GET /gists", "GET /gists/abc", "GET /users/octocat/gists" } },
			{ needs = { gists = "write" }, routes = { "POST /gists", "PATCH /gists/abc", "DELETE /gists/abc" } },
			{ needs = { stars = "read" }, routes = { "GET /user/starred?sort=updated", "GET /users/octocat/starred" } },
			{ needs = { stars = "write" }, routes = { "PUT /user/starred/o/r", "DELETE /user/starred/o/r" } },
			{ needs = { organizations = "read" }, routes = { "GET /user/orgs", "GET /orgs/acme", "GET /orgs/acme/teams" } },
			{ needs = { emails = "read" }, routes = { "GET /user/emails" } },
			{ needs = { repositories = "write" }, routes = {
				"POST /user/repos",
				"POST /orgs/acme/repos",
				"POST /repos/o/r/forks",
			} },
		}
		-- Signed downloads are fetched without credentials, each host only with its row.
		local downloads = {
			{ needs = { code = "read" }, urls = {
				"https://codeload.github.com/o/r/legacy.tar.gz/refs/heads/feature/x?token=SIGNED",
				"https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sig=SIGNED",
				"https://objects.githubusercontent.com/github-production-release-asset-2e65be/1?sig=SIGNED",
				"https://github-releases.githubusercontent.com/1/abc?sig=SIGNED",
			} },
			{ needs = { gists = "read" }, urls = {
				"https://gist.githubusercontent.com/o/aa5a315d61ae9438b18d/raw/3a0f86fb/big%20data.json",
			} },
			{ needs = { actions = "read" }, urls = {
				"https://productionresultssa12.blob.core.windows.net/actions-results/a/logs.txt?sig=SIGNED",
				"https://pipelinesghubeus6.actions.githubusercontent.com/x/logs.zip?sig=SIGNED",
			} },
		}
		-- Exported functions by the access they need; the first group is every base function.
		local functions = {
			{ needs = {}, names = {
				"getAuthenticatedUser", "getUser", "getRateLimit", "listMyRepos", "listUserRepos", "listOrgRepos", "getRepo",
				"listForks", "listLanguages", "getTopics", "listStargazers", "listContributors", "searchRepos", "searchUsers",
			} },
			{ needs = {}, method = "oauth", names = { "listInstallations", "listInstallationRepos" } },
			{ needs = { code = "read" }, names = {
				"getContent", "getTree", "getBlob", "downloadTarball", "listTags", "listCommitComments", "listReleases",
				"getReleaseAsset", "searchCode", "searchCommits",
			} },
			{ needs = { code = "write" }, names = {
				"putFile", "deleteFile", "createRef", "createBlob", "mergeBranch", "createCommitComment", "createRelease",
				"generateReleaseNotes",
			} },
			{ needs = { conversations = "read" }, names = {
				"listMyIssues", "getIssue", "getPull", "listPullReviews", "listCollaborators", "searchIssues",
			} },
			{ needs = { conversations = "write" }, names = {
				"createIssue", "updatePull", "createPullReview", "setLabels", "createMilestone", "createIssueCommentReaction",
			} },
			{ needs = { code = "read", conversations = "read" }, names = {
				"listUserEvents", "listReceivedEvents", "listRepoEvents", "listPullFiles", "listPullCommits", "listPullsForCommit",
			} },
			{ needs = { code = "write", conversations = "write" }, names = { "mergePull", "updatePullBranch" } },
			{ needs = { actions = "read" }, names = { "listWorkflowRuns", "downloadJobLogs", "listCheckRuns", "getCombinedStatus" } },
			{ needs = { actions = "write" }, names = { "dispatchWorkflow", "cancelWorkflowRun", "createCommitStatus" } },
			{ needs = { gists = "read" }, names = { "listGists", "getGist", "downloadGistFile" } },
			{ needs = { gists = "write" }, names = { "createGist", "updateGist", "deleteGist" } },
			{ needs = { stars = "read" }, names = { "listMyStarred", "listUserStarred" } },
			{ needs = { stars = "write" }, names = { "starRepo", "unstarRepo" } },
			{ needs = { organizations = "read" }, names = { "listMyOrgs", "getOrg", "listOrgMembers", "listTeamMembers" } },
			{ needs = { emails = "read" }, names = { "listEmails" } },
			{ needs = { repositories = "write" }, names = { "createRepo", "createOrgRepo", "createFork" } },
		}
		local function checkExports(method, access, levels)
			local result, err = m.exports({}, method, {}, nil, access)
			assert(result and not err and result.type == "result", tostring(err))
			local exported, base = {}, {}
			for _, name in result.exports do
				exported[name] = true
			end
			for _, group in functions do
				local enabled = allows(access, group.needs) and (group.method == nil or group.method == method)
				for _, name in group.names do
					assert((exported[name] == true) == enabled, method .. " " .. name .. " export does not follow access")
					if enabled and next(group.needs) == nil then
						table.insert(base, name)
					end
				end
			end
			if next(levels) == nil then
				m.sortedEqual(base, result.exports)
			elseif levels == top then
				assert(#result.exports == #m.endpoints() + 1 - (if method == "token" then 2 else 0), "full access omits functions")
			end
			local documented = {}
			for name in string.gmatch("\n" .. result.help, "\n([^%s%(]+)%(") do
				table.insert(documented, name)
			end
			m.sortedEqual(documented, m.concat(result.exports))
		end
		local matrices = {
			{},
			{ code = "read", conversations = "read" },
			{ code = "write", conversations = "read" },
			{ code = "read", conversations = "write" },
			{ code = "write", conversations = "write" },
			top,
		}
		for _, row in m.raw.access do
			for index = 2, #row.levels do
				table.insert(matrices, { [row.name] = row.levels[index].value })
			end
		end
		for _, method in { "oauth", "token" } do
			for _, levels in matrices do
				local access = matrix(levels)
				local r, err = m.resolve(publisher, {}, if method == "token" then { token = "fixture-token" } else nil, method, access)
				assert(not err, tostring(err))
				if m.count(r.Scopes) ~= 0 then
					m.fail("GitHub App sign-in requests no scopes, got %s", r.Scopes)
				end
				if method == "oauth" then
					r.Context.Auth[method].access_token = "fixture-token"
				end
				checkExports(method, access, levels)
				for _, group in groups do
					local routes = {}
					for _, route in group.routes do
						table.insert(routes, (string.gsub(route, " /", " " .. api .. "/", 1)))
					end
					m.routes(r, "Bearer fixture-token", allows(access, group.needs), routes)
				end
				for _, group in downloads do
					for _, url in group.urls do
						local recipe, problem = m.recipe(r, "GET", url, nil)
						if not allows(access, group.needs) then
							assert(problem ~= nil, "download host reached without its access: " .. url)
							continue
						end
						assert(problem == nil, url .. ": " .. tostring(problem))
						local headers, prepareError = m.prepare(recipe, r.Context, { Authorization = { "forged" } })
						if prepareError ~= nil or m.header(headers, "Authorization") ~= "" then
							m.fail("signed download %s kept credentials: %s %s", url, headers, prepareError)
						end
					end
				end
				m.routes(r, "Bearer fixture-token", false, {
					"DELETE " .. api .. "/repos/o/r",
					"PATCH " .. api .. "/repos/o/r",
					"POST " .. api .. "/graphql",
					"GET " .. api .. "/repos/o/r/actions/secrets",
					"GET " .. api .. "/repos/o/r/actions/secrets/public-key",
					"GET " .. api .. "/repos/o/r/hooks",
					"GET " .. api .. "/repos/o/r/keys",
					"PUT " .. api .. "/repos/o/r/collaborators/u",
					"POST " .. api .. "/applications/abc/token",
					"DELETE " .. api .. "/installation/token",
					"POST " .. api .. "/credentials/revoke",
					"GET " .. api .. "/authorizations",
					"POST https://github.com/login/oauth/access_token",
					"GET https://api.github.com.evil.test/user",
					"GET " .. api .. "/repos/o/r/contents/%2e%2e%2fsecrets",
					"GET " .. api .. "/repos/o/r/branches/a%2F..%2F..%2Fhooks",
					"GET " .. api .. "/repos/o/r/issues/1%2F..%2F2",
					"GET " .. api .. "/repos/o/r/contents/%252e%252e%252fsecrets",
					"POST " .. api .. "/repos/o/r/branches/a/protection",
					"PATCH " .. api .. "/repos/o/r/issues/1/labels/x",
					"GET " .. api .. "/repos/o/r/git/refs/heads",
					"GET https://uploads.github.com/repos/o/r/releases/1/assets",
					"POST https://uploads.github.com/repos/o/r/releases/1/assets?name=a.zip",
					"POST https://codeload.github.com/o/r/legacy.tar.gz/main",
				})
			end
		end
	end,
}
