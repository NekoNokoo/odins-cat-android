"use client";

import { useState } from "react";
import type { ServerDraft } from "@whitelist/contracts";
import { SectionCard } from "@whitelist/ui/SectionCard";
import { ConnectScreenHero } from "@whitelist/ui/ConnectScreenHero";
import { useI18n } from "@whitelist/ui/OdinI18n";

const initialDraft: ServerDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  transport: "vk-turn-proxy+xray"
};

export function AndroidControlCenter() {
  const { t } = useI18n();
  const [activeTab, setActiveTab] = useState<"server" | "tunnel" | "build">("server");
  const [draft, setDraft] = useState<ServerDraft>(initialDraft);
  const [vkLink, setVKLink] = useState("");
  const [previewActive, setPreviewActive] = useState(false);
  const plannedSocksAddress = "127.0.0.1:58371";
  const apkArtifactPath = "/Users/vladislav/Desktop/odin-one-vk-android-debug.apk";

  return (
    <div className="mobile-stack">
      <ConnectScreenHero
        eyebrow={t("androidConnectScreen")}
        title="Odin One"
        description={t("androidConnectIntro")}
        facts={[
          {
            label: t("status"),
            value: previewActive ? t("androidShellReady") : t("androidBridgePending")
          },
          {
            label: t("transport"),
            value: draft.transport === "vk-turn-proxy+xray" ? t("transportVK") : t("transportDirect")
          },
          {
            label: t("host"),
            value: draft.host || "—"
          },
          {
            label: t("socksProxy"),
            value: plannedSocksAddress
          },
          {
            label: t("androidBuildPath"),
            value: "Next.js export + Tauri 2"
          },
          {
            label: t("androidNativeBridge"),
            value: t("androidBridgePending")
          }
        ]}
        buttonLabel={t("androidPreview")}
        buttonActive={previewActive}
        onButtonClick={() => setPreviewActive((current) => !current)}
      />

      <div className="workspace-tabs" role="tablist" aria-label="Android workspace sections">
        <button
          className={activeTab === "server" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("server")}
          type="button"
        >
          {t("androidTabServer")}
        </button>
        <button
          className={activeTab === "tunnel" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("tunnel")}
          type="button"
        >
          {t("androidTabTunnel")}
        </button>
        <button
          className={activeTab === "build" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("build")}
          type="button"
        >
          {t("androidTabBuild")}
        </button>
      </div>

      {activeTab === "server" ? (
        <SectionCard eyebrow={t("serverInput")} title={t("remoteNode")}>
          <p className="empty-state">{t("androidDesktopParityText")}</p>

          <div className="form-grid mobile-form-grid">
            <label className="input-field">
              <span>{t("host")}</span>
              <input
                value={draft.host}
                onChange={(event) => setDraft((current) => ({ ...current, host: event.target.value }))}
                placeholder="203.0.113.42"
              />
            </label>

            <label className="input-field">
              <span>{t("sshPort")}</span>
              <input
                value={draft.port}
                onChange={(event) => setDraft((current) => ({ ...current, port: Number(event.target.value) || 22 }))}
                placeholder="22"
              />
            </label>

            <label className="input-field">
              <span>{t("user")}</span>
              <input
                value={draft.username}
                onChange={(event) => setDraft((current) => ({ ...current, username: event.target.value }))}
              />
            </label>

            <label className="input-field">
              <span>{t("transportStack")}</span>
              <select
                value={draft.transport}
                onChange={(event) =>
                  setDraft((current) => ({
                    ...current,
                    transport: event.target.value as ServerDraft["transport"]
                  }))
                }
              >
                <option value="vk-turn-proxy+xray">{t("transportVK")}</option>
                <option value="xray">{t("transportDirect")}</option>
              </select>
            </label>

            <label className="input-field input-span mobile-span">
              <span>{t("vkCallLink")}</span>
              <input
                value={vkLink}
                onChange={(event) => setVKLink(event.target.value)}
                placeholder="https://vk.com/call/join/..."
              />
            </label>
          </div>

          <div className="inline-actions">
            <button className="primary" type="button" onClick={() => setPreviewActive(true)}>
              {t("androidShellReady")}
            </button>
            <button className="ghost" type="button" onClick={() => setActiveTab("tunnel")}>
              {t("androidTabTunnel")}
            </button>
          </div>
        </SectionCard>
      ) : null}

      {activeTab === "tunnel" ? (
        <SectionCard eyebrow={t("androidTunnelPlanned")} title={t("isolatedTunnel")}>
          <p className="empty-state">{t("androidTunnelReadyText")}</p>

          <div className="mobile-status-grid check-list">
            <div className="check-row">
              <div>
                <strong>{t("status")}</strong>
                <p>{previewActive ? t("androidShellReady") : t("androidBridgePending")}</p>
              </div>
              <span className={previewActive ? "pill pill-ok" : "pill pill-off"}>
                {previewActive ? t("androidShellReady") : t("androidBridgePending")}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("androidPlannedSocks")}</strong>
                <p>{plannedSocksAddress}</p>
              </div>
              <span className="pill pill-ok">{t("ready")}</span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("androidNativeBridge")}</strong>
                <p>{t("androidBridgePendingText")}</p>
              </div>
              <span className="pill pill-off">{t("androidBridgePending")}</span>
            </div>

            <div className="command-card">
              <strong>{t("safeMode")}</strong>
              <p>{t("safeModeText")}</p>
            </div>
          </div>
        </SectionCard>
      ) : null}

      {activeTab === "build" ? (
        <SectionCard eyebrow={t("androidShellReady")} title={t("androidSharedUi")}>
          <div className="mobile-note-grid">
            <div className="command-card">
              <strong>{t("androidEntryPoint")}</strong>
              <textarea readOnly value="/Users/vladislav/Documents/VPN White List VK/apps/mobile/app/page.tsx" />
            </div>
            <div className="command-card">
              <strong>{t("androidBuildPath")}</strong>
              <textarea readOnly value="npm run mobile:tauri:android:init && npm run mobile:tauri:android:build" />
            </div>
            <div className="command-card">
              <strong>{t("androidArtifactPath")}</strong>
              <textarea readOnly value={apkArtifactPath} />
            </div>
            <div className="command-card">
              <strong>{t("androidDesktopParity")}</strong>
              <p>{t("androidDesktopParityText")}</p>
            </div>
            <div className="command-card">
              <strong>{t("androidSharedUi")}</strong>
              <p>{t("androidSharedUiText")}</p>
            </div>
            <div className="command-card">
              <strong>{t("androidIcons")}</strong>
              <p>{t("androidIconsText")}</p>
            </div>
          </div>

          <div className="mobile-status-grid check-list">
            <div className="check-row">
              <div>
                <strong>{t("androidArtifactPath")}</strong>
                <p>{t("androidArtifactText")}</p>
              </div>
              <span className="pill pill-ok">{t("androidShellReady")}</span>
            </div>
            <div className="check-row">
              <div>
                <strong>{t("androidNativeBridge")}</strong>
                <p>{t("androidBridgePendingText")}</p>
              </div>
              <span className="pill pill-off">{t("androidBridgePending")}</span>
            </div>
          </div>
        </SectionCard>
      ) : null}
    </div>
  );
}
