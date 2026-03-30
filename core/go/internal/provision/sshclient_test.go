package provision

import (
	"errors"
	"testing"
)

func TestIsTransientRemoteReadError(t *testing.T) {
	if !isTransientRemoteReadError(errors.New(`command "cat '/opt/whitelist/profiles/owner-profile.json'" failed: EOF`)) {
		t.Fatal("expected EOF read failure to be treated as transient")
	}

	if !isTransientRemoteReadError(errors.New("command failed: unexpected EOF")) {
		t.Fatal("expected unexpected EOF to be treated as transient")
	}

	if isTransientRemoteReadError(errors.New("command failed: permission denied")) {
		t.Fatal("did not expect non-EOF failure to be treated as transient")
	}
}
