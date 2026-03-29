package provision

import "testing"

func TestGenerateGuestInviteRejectsLocalOwnerClone(t *testing.T) {
	resp := GenerateGuestInvite("example.com", "Friend Laptop")
	if resp.Error == "" {
		t.Fatal("expected local guest invite generation to be rejected")
	}
}
