package main

import "testing"

func TestParseDecision(t *testing.T) {
	id, decision, ok := parseDecision(map[string]any{"request_id": "abc", "decision": "allow"})
	if !ok || id != "abc" || decision != "allow" {
		t.Fatalf("allow: %v %v %v", id, decision, ok)
	}
	_, _, ok = parseDecision(map[string]any{"request_id": "abc", "decision": "deny"})
	if !ok {
		t.Fatal("deny should be accepted")
	}
	for _, decision := range []string{"yes", "always", "allow once", "", "ALLOW"} {
		if _, _, ok := parseDecision(map[string]any{"request_id": "abc", "decision": decision}); ok {
			t.Fatalf("accepted %q", decision)
		}
	}
	if _, _, ok := parseDecision(map[string]any{"text": "同意"}); ok {
		t.Fatal("chat-like payload must not authorize")
	}
	if _, _, ok := parseDecision(nil); ok {
		t.Fatal("nil value must not authorize")
	}
}
