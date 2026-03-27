package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"whitelist-vpn/core/internal/provision"
)

func main() {
	addr := strings.TrimSpace(os.Getenv("MVPD_ADDR"))
	if addr == "" {
		addr = ":8088"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"status":  "ok",
			"service": "whitelist-mvpd",
		})
	})

	mux.HandleFunc("/api/provision/plan", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var req provision.Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp := provision.BuildPlan(req)
		writeJSON(w, http.StatusOK, resp)
	})

	mux.HandleFunc("/api/provision/validate", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var req provision.Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp := provision.Validate(req)
		status := http.StatusOK
		if !resp.OK && resp.Error != "" {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, resp)
	})

	mux.HandleFunc("/api/provision/deploy", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var req provision.Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp := provision.StartDeployment(req)
		writeJSON(w, http.StatusAccepted, resp)
	})

	mux.HandleFunc("/api/provision/deploy/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		id := strings.TrimPrefix(r.URL.Path, "/api/provision/deploy/")
		resp, ok := provision.GetDeployment(id)
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "deployment not found"})
			return
		}
		writeJSON(w, http.StatusOK, resp)
	})

	mux.HandleFunc("/api/local-tunnel/start", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			Server provision.Server `json:"server"`
			Secret string           `json:"secret"`
			VKLink string           `json:"vkLink"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp := provision.StartLocalTunnel(provision.Request{
			Server: payload.Server,
			Secret: payload.Secret,
		}, payload.VKLink)
		status := http.StatusAccepted
		if resp.CooldownSecs > 0 {
			status = http.StatusTooManyRequests
		}
		writeJSON(w, status, resp)
	})

	mux.HandleFunc("/api/local-tunnel/stop", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		writeJSON(w, http.StatusOK, provision.StopLocalTunnel())
	})

	mux.HandleFunc("/api/local-tunnel/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		writeJSON(w, http.StatusOK, provision.GetLocalTunnelState())
	})

	mux.HandleFunc("/api/local-tunnel/test", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			URL string `json:"url"`
		}
		if r.Body != nil {
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil && err != io.EOF {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
				return
			}
		}

		state := provision.TestLocalTunnel(payload.URL)
		status := http.StatusOK
		if state.LastTest != nil && state.LastTest.Status == "failed" {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, state)
	})

	mux.HandleFunc("/api/system-proxy/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		writeJSON(w, http.StatusOK, provision.GetSystemProxyState())
	})

	mux.HandleFunc("/api/system-proxy/enable", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			SOCKSAddress string `json:"socksAddress"`
		}
		if r.Body != nil {
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil && err != io.EOF {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
				return
			}
		}

		state := provision.EnableSystemProxy(payload.SOCKSAddress)
		status := http.StatusOK
		if state.Error != "" {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, state)
	})

	mux.HandleFunc("/api/system-proxy/disable", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		state := provision.DisableSystemProxy()
		status := http.StatusOK
		if state.Error != "" {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, state)
	})

	mux.HandleFunc("/api/profile/owner", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		host := strings.TrimSpace(r.URL.Query().Get("host"))
		resp := provision.GetLocalOwnerProfile(host)
		status := http.StatusOK
		if resp.Error != "" && resp.Exists {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, resp)
	})

	mux.HandleFunc("/api/profile/guest", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			Server provision.Server `json:"server"`
			Secret string           `json:"secret"`
			Host   string           `json:"host"`
			Name   string           `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		if payload.Secret == "" {
			resp := provision.GenerateGuestInvite(payload.Host, payload.Name)
			status := http.StatusOK
			if resp.Error != "" {
				status = http.StatusBadRequest
			}
			writeJSON(w, status, resp)
			return
		}

		resp, err := provision.IssueRemoteGuestProfile(provision.Request{
			Server: payload.Server,
			Secret: payload.Secret,
		}, payload.Name)
		status := http.StatusOK
		if err != nil {
			status = http.StatusBadRequest
			resp = provision.InviteProfileResponse{Error: err.Error()}
		}
		writeJSON(w, status, resp)
	})

	mux.HandleFunc("/api/profile/guest/list", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			Server provision.Server `json:"server"`
			Secret string           `json:"secret"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		items, err := provision.ListRemoteGuestProfiles(provision.Request{
			Server: payload.Server,
			Secret: payload.Secret,
		})
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
	})

	mux.HandleFunc("/api/profile/guest/revoke", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			Server  provision.Server `json:"server"`
			Secret  string           `json:"secret"`
			GuestID string           `json:"guestId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp, err := provision.RevokeRemoteGuestProfile(provision.Request{
			Server: payload.Server,
			Secret: payload.Secret,
		}, payload.GuestID)
		status := http.StatusOK
		if err != nil {
			status = http.StatusBadRequest
			resp = provision.InviteProfileResponse{Error: err.Error()}
		}
		writeJSON(w, status, resp)
	})

	mux.HandleFunc("/api/profile/import", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}

		var payload struct {
			ShareCode string `json:"shareCode"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		resp := provision.ImportInvite(payload.ShareCode)
		status := http.StatusOK
		if resp.Error != "" {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, resp)
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           withCORS(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("whitelist-mvpd listening on %s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}
