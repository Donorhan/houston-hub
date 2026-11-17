-- Full access on Umami Cloud: requests use the account region's prefix, and self-hosted operations stay absent.
return {
 scenario={access={analytics="write",websites="write",reports="write",replays="write",errors="write",boards="write",links="write",pixels="write",shares="write",teams="write",account="write",administration="write",collection="write",system="read"},
  config={deployment="cloud"},auth_method="token",auth_config={key="fixture-umami-key"}},
 configure=function()
  requests={}
  http={request=function(req)
   table.insert(requests,req)
   return fixture.operation({statusCode=200,headers={},body=fixture.reader('{"ok":true}')})
  end}
 end,
 run=function(c)
  assert(c.administration.users.create==nil and c.profile.updatePassword==nil,"Cloud exposes self-hosted operations")
  assert(c.system.heartbeat().ok)
  assert(requests[1].method=="GET" and requests[1].url=="https://api.umami.is/v1/heartbeat",requests[1].url)
  assert(c.teams.delete({teamId="team"}).ok)
  assert(requests[2].method=="DELETE" and requests[2].url=="https://api.umami.is/v1/teams/team",requests[2].url)
 end,
}
