package manifest

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

const accessRows = `[
	{"name":"code","label":"Code","levels":[{"value":"none","label":"None"},{"value":"read","label":"Read"},{"value":"write","label":"Write"}],"default":"read"},
	{"name":"gists","label":"Gists","levels":[{"value":"none","label":"None"},{"value":"read","label":"Read"},{"value":"write","label":"Write"}],"default":"none"}
]`

func accessManifest(t *testing.T, scopes, proxy string) *Manifest {
	t.Helper()
	m, err := Parse([]byte(fmt.Sprintf(`{
		"schema_version":2,"name":"Access fixture","files":["main.lua"],
		"access":%s,
		"auth":{"oauth":{"type":"oauth2","label":"OAuth","authorize_url":"https://example.com/auth","token_url":"https://example.com/token","client_id":"{{publisher.client_id}}","client_auth":"none","scopes":%s}},
		"publisher":{"client_id":{"type":"string","label":"Client","default":"fixture-client"}},
		"proxy":%s
	}`, accessRows, scopes, proxy)))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestAccessLevelsSelectScopesAndRules(t *testing.T) {
	m := accessManifest(t, `[
		{"values":["user"]},
		{"if":"{{ is access.code \"read\" }}","values":["code.readonly"]},
		{"if":"{{ is access.code \"write\" }}","values":["code"]},
		{"if":"{{ allows access.gists \"read\" }}","values":["gist"]}
	]`, `[
		{"match":{"protocol":"http","host":["base.example.com"]},"action":{}},
		{"if":"{{ allows access.code \"read\" }}","match":{"protocol":"http","host":["code.example.com"]},"action":{}},
		{"if":"{{ and (allows access.code \"write\") (allows access.gists \"write\") }}","match":{"protocol":"http","host":["both.example.com"]},"action":{}}
	]`)
	for _, tc := range []struct {
		code, gists string
		scopes      []string
		rules       []int
	}{
		{"none", "none", []string{"user"}, []int{0}},
		{"read", "none", []string{"user", "code.readonly"}, []int{0, 1}},
		{"write", "read", []string{"user", "code", "gist"}, []int{0, 1}},
		{"write", "write", []string{"user", "code", "gist"}, []int{0, 1, 2}},
	} {
		r, err := m.Resolve(Inputs{Access: map[string]string{"code": tc.code, "gists": tc.gists}, Method: "oauth"})
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(r.Scopes, tc.scopes) || !reflect.DeepEqual(r.ProxyIndices, tc.rules) {
			t.Errorf("code=%s gists=%s: scopes=%v rules=%v", tc.code, tc.gists, r.Scopes, r.ProxyIndices)
		}
		if !reflect.DeepEqual(r.Access, map[string]string{"code": tc.code, "gists": tc.gists}) {
			t.Errorf("access=%v", r.Access)
		}
	}
}

func TestOAuthAccessMustRequestAScope(t *testing.T) {
	m := accessManifest(t, `[{"if":"{{ allows access.code \"read\" }}","values":["code"]}]`, `[{"match":{"protocol":"http","host":["example.com"]},"action":{}}]`)
	if _, err := m.Resolve(Inputs{Access: map[string]string{"code": "none", "gists": "none"}, Method: "oauth"}); err == nil || !strings.Contains(err.Error(), "requests no OAuth scopes") {
		t.Fatalf("empty scope request: %v", err)
	}
	if _, err := m.ResolveDraft(Inputs{Access: map[string]string{"code": "none"}, Method: "oauth"}); err != nil {
		t.Fatalf("drafts stay editable: %v", err)
	}
}

func TestSavedConnectionsNameEveryRowWhileDraftsUseDefaults(t *testing.T) {
	m := accessManifest(t, `[{"values":["user"]}]`, `[{"match":{"protocol":"http","host":["example.com"]},"action":{}}]`)
	draft, err := m.ResolveDraft(Inputs{Access: map[string]string{"gists": "write"}, Method: "oauth"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(draft.Access, map[string]string{"code": "read", "gists": "write"}) {
		t.Fatalf("draft access=%v", draft.Access)
	}
	for input, want := range map[string]map[string]string{
		"access.code requires a level":     {"gists": "write"},
		`access.code has no level "admin"`: {"code": "admin", "gists": "none"},
		"undeclared access row repos":      {"code": "read", "gists": "none", "repos": "read"},
	} {
		if _, err := m.Resolve(Inputs{Access: want, Method: "oauth"}); err == nil || !strings.Contains(err.Error(), input) {
			t.Errorf("%v: want %q, got %v", want, input, err)
		}
	}
}

func TestAccessRowsAndPredicatesAreValidated(t *testing.T) {
	row := func(levels, def string) string {
		return fmt.Sprintf(`[{"name":"code","label":"Code","levels":%s,"default":%q}]`, levels, def)
	}
	three := `[{"value":"none","label":"None"},{"value":"read","label":"Read"},{"value":"write","label":"Write"}]`
	for _, tc := range []struct{ name, access, config, scope, proxy, want string }{
		{name: "valid", access: row(three, "read")},
		{name: "none first", access: row(`[{"value":"read","label":"Read"},{"value":"none","label":"None"}]`, "read"), want: "none must be the first level"},
		{name: "one level", access: row(`[{"value":"read","label":"Read"}]`, "read"), want: "rows need 2 to 4 levels"},
		{name: "default", access: row(three, "admin"), want: "default must be one of its levels"},
		{name: "duplicate level", access: row(`[{"value":"read","label":"Read"},{"value":"read","label":"Again"}]`, "read"), want: "invalid or duplicate level"},
		{name: "config access", access: row(three, "read"), config: `,"config":{"access":{"type":"string","label":"Access"}}`, want: "config.access is replaced by access rows"},
		{name: "unknown level", access: row(three, "read"), proxy: `{{ allows access.code "admin" }}`, want: "access.code has no level admin"},
		{name: "unknown row", access: row(three, "read"), proxy: `{{ allows access.repos "read" }}`, want: "undeclared reference access.repos"},
		{name: "exact level outside scopes", access: row(three, "read"), proxy: `{{ is access.code "read" }}`, want: "allowed only on scope groups"},
		{name: "allows on config", access: row(three, "read"), config: `,"config":{"mode":{"type":"string","label":"Mode"}}`, proxy: `{{ allows config.mode "read" }}`, want: "allows requires an access row reference"},
		{name: "exact level on scopes", access: row(three, "read"), scope: `{{ is access.code "write" }}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			proxyIf, scopeIf := "", ""
			if tc.proxy != "" {
				proxyIf = fmt.Sprintf(`"if":%q,`, tc.proxy)
			}
			if tc.scope != "" {
				scopeIf = fmt.Sprintf(`"if":%q,`, tc.scope)
			}
			raw := fmt.Sprintf(`{"schema_version":2,"name":"Rows","files":["main.lua"],"access":%s%s,
				"auth":{"oauth":{"type":"oauth2","label":"OAuth","authorize_url":"https://example.com/auth","token_url":"https://example.com/token","client_id":"{{publisher.client_id}}","client_auth":"none","scopes":[{%s"values":["scope"]}]}},
				"publisher":{"client_id":{"type":"string","label":"Client"}},
				"proxy":[{"match":{"protocol":"http","host":["base.example.com"]},"action":{}},{%s"match":{"protocol":"http","host":["example.com"]},"action":{}}]}`, tc.access, tc.config, scopeIf, proxyIf)
			_, err := Parse([]byte(raw))
			if tc.want == "" && err != nil || tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
				t.Fatalf("want %q, got %v", tc.want, err)
			}
		})
	}
}

func TestNativeConnectorsGateWritesOnTheirSingleRow(t *testing.T) {
	native := func(access string) string {
		return fmt.Sprintf(`{"schema_version":2,"name":"Database","files":["main.lua"],%s
			"config":{"password":{"type":"secret","label":"Password","required":true}},
			"proxy":[{"match":{"protocol":"postgres"},"action":{"connection":{"host":"db.example.com","database":"app","user":"app","password":"{{config.password}}"}}}]}`, access)
	}
	two := `"access":[{"name":"a","label":"A","levels":[{"value":"read","label":"Read"},{"value":"write","label":"Write"}],"default":"read"},{"name":"b","label":"B","levels":[{"value":"read","label":"Read"},{"value":"write","label":"Write"}],"default":"read"}],`
	if _, err := Parse([]byte(native(two))); err == nil || !strings.Contains(err.Error(), "native protocols allow one access row") {
		t.Fatalf("native connector with two rows: %v", err)
	}
	unrestricted, err := Parse([]byte(native("")))
	if err != nil || unrestricted.NativeWrites(nil) {
		t.Fatalf("native connector without a row must stay read-only: %v", err)
	}
	m, err := Parse([]byte(native(`"access":[{"name":"data","label":"Access","levels":[{"value":"read","label":"Read"},{"value":"draft","label":"Read and draft"},{"value":"write","label":"Write"}],"default":"read"}],`)))
	if err != nil {
		t.Fatal(err)
	}
	for level, writes := range map[string]bool{"read": false, "draft": true, "write": true} {
		if got := m.NativeWrites(map[string]string{"data": level}); got != writes {
			t.Errorf("%s: writes=%v", level, got)
		}
	}
}

func TestSetupLinkCarriesChosenLevels(t *testing.T) {
	m, err := Parse([]byte(fmt.Sprintf(`{"schema_version":2,"name":"Token","files":["main.lua"],"access":%s,
		"auth":{"token":{"type":"manual","label":"Token","config":{"token":{"type":"secret","label":"Token","required":true}},
			"setup_url":"https://example.com/tokens/new?name=Houston","setup_params":{"contents":"code","gists":"gists"}}},
		"proxy":[{"match":{"protocol":"http","host":["example.com"]},"action":{"headers":{"set":{"Authorization":"Bearer {{auth.token.token}}"}}}}]}`, accessRows)))
	if err != nil {
		t.Fatal(err)
	}
	link := m.Auth["token"].SetupLink(map[string]string{"code": "write", "gists": "none"})
	if link != "https://example.com/tokens/new?contents=write&name=Houston" {
		t.Fatalf("link=%s", link)
	}
}

func TestPublicationRequiresTheCurrentSchemaVersion(t *testing.T) {
	raw := `{"schema_version":1,"name":"Legacy","files":["main.lua"],"config":{"access":{"type":"string","label":"Access","options":[{"value":"read-only","label":"Read"},{"value":"read-write","label":"Write"}]}},"proxy":[{"match":{"protocol":"http","host":["example.com"]},"action":{}}]}`
	if _, err := Parse([]byte(raw)); err == nil || !strings.Contains(err.Error(), "migration guide") {
		t.Fatalf("publication: %v", err)
	}
	var pinned Manifest
	if err := pinned.UnmarshalJSON([]byte(raw)); err != nil {
		t.Fatalf("pinned v1 snapshot: %v", err)
	}
	r, err := pinned.Resolve(Inputs{})
	if err != nil || r.PublicConfig["access"] != "read-only" {
		t.Fatalf("pinned v1 resolution: %v %v", r, err)
	}
}
