package manifest

import (
	"regexp"
	"strings"
	"testing"
)

const reauthorizeFixture = `{
	"schema_version":2,"name":"Reauthorize fixture","files":["main.lua"],
	"access":[{"name":"data","label":"Access","levels":[{"value":"read","label":"Read"},{"value":"write","label":"Write"}],"default":"read"}],
	"config":{
		"time_zone":{"type":"string","label":"Time zone"@time_zone@},
		"workspace":{"type":"string","label":"Workspace","required":true@workspace@},
		"region":{"type":"string","label":"Region"@region@},
		"archive":{"type":"boolean","label":"Archive"@archive@},
		"folders":{"type":"string","label":"Folders","if":"{{ isDefined config.archive }}"},
		"admin":{"type":"boolean","label":"Admin"@admin@}
	},
	"publisher":{"client_id":{"type":"string","label":"Client","default":"fixture-client"@client_id@}},
	"auth":{
		"oauth":{"type":"oauth2","label":"OAuth","authorize_url":"https://example.com/auth","token_url":"https://example.com/token","client_id":"{{publisher.client_id}}","client_auth":"none","authorize_params":{"region":"{{config.region}}"},
			"scopes":[{"values":["read"]},{"if":"{{ is config.admin true }}","values":["admin"]}]},
		"token":{"type":"manual","label":"Token","config":{"token":{"type":"secret","label":"Token","required":true@token@}}}
	},
	"proxy":[{"match":{"protocol":"http","host":["api.example.com"]},"action":{"headers":{"set":{"X-Workspace":"{{config.workspace}}","Authorization":"Bearer {{auth.oauth.access_token || auth.token.token}}"}}}}]
}`

func reauthorizeManifest(optOut string) []byte {
	return []byte(regexp.MustCompile(`@(\w+)@`).ReplaceAllStringFunc(reauthorizeFixture, func(marker string) string {
		if marker == "@"+optOut+"@" {
			return `,"reauthorize_on_change":false`
		}
		return ""
	}))
}

func TestReauthorizeOptOutOnlyForUnreferencedConfigFields(t *testing.T) {
	m, err := Parse(reauthorizeManifest("time_zone"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Config["time_zone"].Reauthorizes() || !m.Config["workspace"].Reauthorizes() {
		t.Fatalf("time_zone reauthorizes=%v, workspace reauthorizes=%v", m.Config["time_zone"].Reauthorizes(), m.Config["workspace"].Reauthorizes())
	}
	for optOut, want := range map[string]string{
		"workspace": "config.workspace: reauthorize_on_change cannot be false",
		"region":    "config.region: reauthorize_on_change cannot be false",
		"archive":   "config.archive: reauthorize_on_change cannot be false",
		"admin":     "config.admin: reauthorize_on_change cannot be false",
		"client_id": "publisher.client_id: reauthorize_on_change is only valid on config fields",
		"token":     "auth.token.token: reauthorize_on_change is only valid on config fields",
	} {
		if _, err := Parse(reauthorizeManifest(optOut)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("opting out %s: err=%v, want %q", optOut, err, want)
		}
	}
}
