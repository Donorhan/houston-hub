-- Routes from Umami's official API and the exports they back, checked on every deployment
-- with each access row at each of its levels.
return {contract=function(m)
 -- method, path, row, read, available on Umami Cloud
 local routes={{"POST","/2fa/disable","account",false,true},
{"POST","/2fa/setup/cancel","account",false,true},
{"POST","/2fa/setup/confirm","account",false,true},
{"POST","/2fa/setup/initiate","account",false,true},
{"GET","/2fa/status","account",true,true},
{"POST","/admin/2fa/global","administration",false,true},
{"GET","/admin/teams","administration",true,true},
{"POST","/admin/teams/123e4567-e89b-42d3-a456-426614174000/2fa","administration",false,true},
{"GET","/admin/users","administration",true,true},
{"DELETE","/admin/users/123e4567-e89b-42d3-a456-426614174000/2fa","administration",false,true},
{"GET","/admin/users/123e4567-e89b-42d3-a456-426614174000/2fa","administration",true,true},
{"POST","/admin/users/123e4567-e89b-42d3-a456-426614174000/2fa","administration",false,true},
{"GET","/admin/websites","administration",true,true},
{"POST","/auth/logout","account",false,true},
{"POST","/auth/sso","account",false,true},
{"GET","/auth/subscription","account",true,true},
{"POST","/auth/verify","account",true,true},
{"POST","/batch","collection",false,true},
{"GET","/boards","boards",true,true},
{"POST","/boards","boards",false,true},
{"DELETE","/boards/123e4567-e89b-42d3-a456-426614174000","boards",false,true},
{"GET","/boards/123e4567-e89b-42d3-a456-426614174000","boards",true,true},
{"POST","/boards/123e4567-e89b-42d3-a456-426614174000","boards",false,true},
{"POST","/boards/123e4567-e89b-42d3-a456-426614174000/clone","boards",false,true},
{"GET","/boards/123e4567-e89b-42d3-a456-426614174000/shares","boards",true,true},
{"POST","/boards/123e4567-e89b-42d3-a456-426614174000/shares","boards",false,true},
{"GET","/dashboard","boards",true,true},
{"POST","/dashboard","boards",false,true},
{"GET","/heartbeat","system",true,true},
{"GET","/links","links",true,true},
{"POST","/links","links",false,true},
{"GET","/links/charts","links",true,true},
{"DELETE","/links/123e4567-e89b-42d3-a456-426614174000","links",false,true},
{"GET","/links/123e4567-e89b-42d3-a456-426614174000","links",true,true},
{"POST","/links/123e4567-e89b-42d3-a456-426614174000","links",false,true},
{"GET","/links/123e4567-e89b-42d3-a456-426614174000/shares","links",true,true},
{"POST","/links/123e4567-e89b-42d3-a456-426614174000/shares","links",false,true},
{"GET","/me","account",true,true},
{"GET","/me/api-keys","account",true,true},
{"POST","/me/api-keys","account",false,true},
{"DELETE","/me/api-keys/123e4567-e89b-42d3-a456-426614174000","account",false,true},
{"POST","/me/password","account",false,false},
{"GET","/me/teams","account",true,true},
{"GET","/me/websites","account",true,true},
{"GET","/pixels","pixels",true,true},
{"POST","/pixels","pixels",false,true},
{"GET","/pixels/charts","pixels",true,true},
{"DELETE","/pixels/123e4567-e89b-42d3-a456-426614174000","pixels",false,true},
{"GET","/pixels/123e4567-e89b-42d3-a456-426614174000","pixels",true,true},
{"POST","/pixels/123e4567-e89b-42d3-a456-426614174000","pixels",false,true},
{"GET","/pixels/123e4567-e89b-42d3-a456-426614174000/shares","pixels",true,true},
{"POST","/pixels/123e4567-e89b-42d3-a456-426614174000/shares","pixels",false,true},
{"GET","/realtime/123e4567-e89b-42d3-a456-426614174000","analytics",true,true},
{"POST","/record","collection",false,true},
{"GET","/scripts/telemetry","system",true,true},
{"POST","/send","collection",false,true},
{"POST","/share","shares",false,true},
{"DELETE","/share/id/123e4567-e89b-42d3-a456-426614174000","shares",false,true},
{"GET","/share/id/123e4567-e89b-42d3-a456-426614174000","shares",true,true},
{"POST","/share/id/123e4567-e89b-42d3-a456-426614174000","shares",false,true},
{"GET","/share/xxxxxxxx","shares",true,true},
{"GET","/teams","teams",true,true},
{"POST","/teams","teams",false,true},
{"POST","/teams/join","teams",false,true},
{"DELETE","/teams/123e4567-e89b-42d3-a456-426614174000","teams",false,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000","teams",true,true},
{"POST","/teams/123e4567-e89b-42d3-a456-426614174000","teams",false,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/boards","teams",true,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/links","teams",true,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/pixels","teams",true,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/users","teams",true,true},
{"POST","/teams/123e4567-e89b-42d3-a456-426614174000/users","teams",false,true},
{"DELETE","/teams/123e4567-e89b-42d3-a456-426614174000/users/123e4567-e89b-42d3-a456-426614174000","teams",false,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/users/123e4567-e89b-42d3-a456-426614174000","teams",true,true},
{"POST","/teams/123e4567-e89b-42d3-a456-426614174000/users/123e4567-e89b-42d3-a456-426614174000","teams",false,true},
{"GET","/teams/123e4567-e89b-42d3-a456-426614174000/websites","teams",true,true},
{"POST","/users","administration",false,false},
{"DELETE","/users/123e4567-e89b-42d3-a456-426614174000","administration",false,false},
{"GET","/users/123e4567-e89b-42d3-a456-426614174000","administration",true,false},
{"POST","/users/123e4567-e89b-42d3-a456-426614174000","administration",false,false},
{"GET","/users/123e4567-e89b-42d3-a456-426614174000/teams","administration",true,false},
{"GET","/users/123e4567-e89b-42d3-a456-426614174000/websites","administration",true,false},
{"GET","/websites","websites",true,true},
{"POST","/websites","websites",false,true},
{"GET","/websites/charts","websites",true,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000","websites",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000","websites",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000","websites",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/active","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/annotations","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/annotations","reports",false,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000/annotations/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/annotations/123e4567-e89b-42d3-a456-426614174000","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/annotations/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/attribution","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/breakdown","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/daterange","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/stats","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/values","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/123e4567-e89b-42d3-a456-426614174000","errors",true,true},
{"PATCH","/websites/123e4567-e89b-42d3-a456-426614174000/errors/123e4567-e89b-42d3-a456-426614174000","errors",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/123e4567-e89b-42d3-a456-426614174000/events","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/123e4567-e89b-42d3-a456-426614174000/events/123e4567-e89b-42d3-a456-426614174000","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/errors/123e4567-e89b-42d3-a456-426614174000/values","errors",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot/array-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot/date-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot/numeric-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot/numeric-stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data-pivot/property-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/events","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/fields","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/properties","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/values","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/event-data/123e4567-e89b-42d3-a456-426614174000","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/events","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/events/series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/events/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/export","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/funnels","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/funnels","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/funnels/stats","reports",true,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000/funnels/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/funnels/123e4567-e89b-42d3-a456-426614174000","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/funnels/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/funnels/123e4567-e89b-42d3-a456-426614174000/stats","reports",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/goals","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/goals","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/goals/stats","reports",true,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000/goals/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/goals/123e4567-e89b-42d3-a456-426614174000","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/goals/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/goals/123e4567-e89b-42d3-a456-426614174000/stats","reports",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/heatmaps","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/journeys","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/metrics","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/metrics/expanded","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/pageviews","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/performance/chart","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/performance/metrics","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/performance/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/recorder","replays",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/replays","replays",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/replays/saved","replays",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/replays/saved/123e4567-e89b-42d3-a456-426614174000","replays",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/replays/saved/123e4567-e89b-42d3-a456-426614174000","replays",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/replays/123e4567-e89b-42d3-a456-426614174000","replays",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/reset","websites",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/retention","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/revenue/chart","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/revenue/metrics","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/revenue/sessions","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/revenue/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/segments","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/segments","reports",false,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000/segments/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/segments/123e4567-e89b-42d3-a456-426614174000","reports",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/segments/123e4567-e89b-42d3-a456-426614174000","reports",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data-pivot","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/array-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/date-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/numeric-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/numeric-stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/properties","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/property-series","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/session-data/values","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/stats","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/weekly","analytics",true,true},
{"DELETE","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/123e4567-e89b-42d3-a456-426614174000","analytics",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/123e4567-e89b-42d3-a456-426614174000","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/123e4567-e89b-42d3-a456-426614174000/activity","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/123e4567-e89b-42d3-a456-426614174000/properties","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/sessions/123e4567-e89b-42d3-a456-426614174000/replays","replays",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/shares","shares",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/shares","shares",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/stats","analytics",true,true},
{"POST","/websites/123e4567-e89b-42d3-a456-426614174000/transfer","websites",false,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/utm/metrics","analytics",true,true},
{"GET","/websites/123e4567-e89b-42d3-a456-426614174000/values","analytics",true,true}}
 -- Exports per row; * marks those only self-hosted installations offer.
 local exports={
  account={read=[[profile.apiKeys.list profile.get profile.subscription profile.teams profile.twoFactor.status profile.verify
   profile.websites]],
   write=[[profile.apiKeys.create profile.apiKeys.delete profile.logout profile.sso profile.twoFactor.cancelSetup
   profile.twoFactor.confirmSetup profile.twoFactor.disable profile.twoFactor.initiateSetup
   profile.updatePassword*]]},
  administration={read=[[administration.teams administration.users.get* administration.users.list administration.users.teams*
   administration.users.twoFactor.status administration.users.websites* administration.websites]],
   write=[[administration.setTeamTwoFactorPolicy administration.setTwoFactorPolicy administration.users.create*
   administration.users.delete* administration.users.twoFactor.disable administration.users.twoFactor.setPolicy
   administration.users.update*]]},
  analytics={read=[[websites.analytics.active websites.analytics.attribution websites.analytics.breakdown
   websites.analytics.dateRange websites.analytics.expandedMetrics websites.analytics.journeys
   websites.analytics.metrics websites.analytics.pageviews websites.analytics.realtime
   websites.analytics.retention websites.analytics.stats websites.analytics.utmMetrics websites.analytics.values
   websites.eventData.arraySeries websites.eventData.dateSeries websites.eventData.events
   websites.eventData.fields websites.eventData.get websites.eventData.list websites.eventData.numericSeries
   websites.eventData.numericStats websites.eventData.pivot websites.eventData.properties
   websites.eventData.propertySeries websites.eventData.stats websites.eventData.values websites.events.list
   websites.events.series websites.events.stats websites.export websites.performance.chart
   websites.performance.metrics websites.performance.stats websites.replays.heatmaps websites.revenue.chart
   websites.revenue.metrics websites.revenue.sessions websites.revenue.stats websites.sessionData.arraySeries
   websites.sessionData.dateSeries websites.sessionData.numericSeries websites.sessionData.numericStats
   websites.sessionData.pivot websites.sessionData.properties websites.sessionData.propertySeries
   websites.sessionData.stats websites.sessionData.values websites.sessions.activity websites.sessions.get
   websites.sessions.list websites.sessions.properties websites.sessions.stats websites.sessions.weekly]],
   write=[[websites.sessions.delete]]},
  boards={read=[[boards.dashboard.get boards.get boards.list boards.shares.list]],
   write=[[boards.clone boards.create boards.dashboard.update boards.delete boards.shares.create boards.update]]},
  collection={read="",
   write=[[collection.batch collection.record collection.send]]},
  errors={read=[[websites.errors.event websites.errors.events websites.errors.issue websites.errors.issueValues
   websites.errors.list websites.errors.stats websites.errors.values]],
   write=[[websites.errors.updateIssue]]},
  links={read=[[links.charts links.get links.list links.shares.list]],
   write=[[links.create links.delete links.shares.create links.update]]},
  pixels={read=[[pixels.charts pixels.get pixels.list pixels.shares.list]],
   write=[[pixels.create pixels.delete pixels.shares.create pixels.update]]},
  replays={read=[[websites.replays.get websites.replays.isSaved websites.replays.list websites.replays.recorderConfig
   websites.replays.saved websites.sessions.replays]],
   write=[[websites.replays.save]]},
  reports={read=[[websites.annotations.get websites.annotations.list websites.funnels.get websites.funnels.list
   websites.funnels.savedStats websites.funnels.stats websites.goals.get websites.goals.list
   websites.goals.savedStats websites.goals.stats websites.segments.get websites.segments.list]],
   write=[[websites.annotations.create websites.annotations.delete websites.annotations.update websites.funnels.create
   websites.funnels.delete websites.funnels.update websites.goals.create websites.goals.delete
   websites.goals.update websites.segments.create websites.segments.delete websites.segments.update]]},
  shares={read=[[shares.bySlug shares.get websites.shares.list]],
   write=[[shares.create shares.delete shares.update websites.shares.create]]},
  system={read=[[system.heartbeat system.telemetryScript]]},
  teams={read=[[teams.boards teams.get teams.links teams.list teams.members.get teams.members.list teams.pixels teams.websites]],
   write=[[teams.create teams.delete teams.join teams.members.create teams.members.delete teams.members.update
   teams.update]]},
  websites={read=[[websites.charts websites.get websites.list]],
   write=[[websites.create websites.delete websites.reset websites.transfer websites.update]]},
 }
 local rows={"analytics","websites","reports","replays","errors","boards","links","pixels","shares","teams","account","administration","collection","system"}
 local levels={none={},read={read=true},write={read=true,write=true}}
 local deployments={cloud="https://api.umami.is/v1",us="https://api.umami.is/v1/us",eu="https://api.umami.is/v1/eu",
  ["self-hosted"]="https://analytics.example.com/api"}
 for deployment,base in deployments do
  local host=string.match(base,"^https://([^/]+)")
  local config={deployment=deployment,host=host}
  local cloud=deployment~="self-hosted"
  -- Three rotations give every row each of its levels, next to other rows at different levels.
  for rotation=0,2 do
   local access,parts={},{deployment}
   for index,row in rows do
    local choices={}
    for _,declared in m.raw.access do
     if declared.name==row then for _,level in declared.levels do table.insert(choices,level.value) end end
    end
    access[row]=choices[(index+rotation)%#choices+1]
    table.insert(parts,row.."="..access[row])
   end
   local label=table.concat(parts," ")
   local connection,err=m.resolve(nil,config,{key="fixture-umami-key"},"token",access)
   assert(connection and not err,tostring(err))
   for _,route in routes do
    local granted=levels[access[route[3]]]
    local allowed=(route[5] or not cloud) and granted[if route[4] then "read" else "write"]==true
    m.routes(connection,"Bearer fixture-umami-key",allowed,{route[1].." "..base..route[2]})
   end
   m.routes(connection,"",false,{"GET https://"..host..".evil.test"..string.sub(base,#host+9).."/me","GET https://evil.test/api/me",
    "POST "..base.."/auth/login"})
   for other,prefix in deployments do
    if other~=deployment then m.routes(connection,"",false,{"GET https://"..host..string.sub(prefix,string.find(prefix,"/",9)).."/me"}) end
   end
   local want={}
   for row,names in exports do
    local granted=levels[access[row]]
    for _,kind in {"read","write"} do
     if granted[kind] then
      for name in string.gmatch(names[kind],"%S+") do
       local selfHosted=string.sub(name,-1)=="*"
       if not (selfHosted and cloud) then table.insert(want,if selfHosted then string.sub(name,1,-2) else name) end
      end
     end
    end
   end
   local result,problem=m.exports(config,"token",nil,nil,access)
   assert(result and not problem,tostring(problem))
   assert(result.type=="result",label..": "..tostring(result.error))
   m.sortedEqual(want,result.exports)
  end
  local connection=assert(m.resolve(nil,config,{key="fixture-umami-key"},"token"))
  m.rejectOverrides(connection,{"GET "..base.."/websites"})
 end
end}
