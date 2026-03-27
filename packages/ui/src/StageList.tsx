import type { DeployStage } from "@whitelist/contracts";

const defaultStatusMap: Record<DeployStage["status"], string> = {
  queued: "Queued",
  current: "In progress",
  done: "Done",
  failed: "Failed"
};

export function StageList({
  stages,
  statusLabels
}: {
  stages: DeployStage[];
  statusLabels?: Partial<Record<DeployStage["status"], string>>;
}) {
  const statusMap = { ...defaultStatusMap, ...statusLabels };
  return (
    <div style={{ display: "grid", gap: 12 }}>
      {stages.map((stage, index) => (
        <div
          key={stage.id}
          style={{
            display: "grid",
            gridTemplateColumns: "40px 1fr",
            gap: 12,
            alignItems: "start"
          }}
        >
          <div
            aria-hidden="true"
            style={{
              width: 40,
              height: 40,
              borderRadius: 999,
              border: "1px solid #111",
              background:
                stage.status === "done" ? "#111" : stage.status === "current" ? "#efefea" : "transparent",
              color: stage.status === "done" ? "#fff" : "#111",
              display: "grid",
              placeItems: "center",
              fontSize: "0.8rem"
            }}
          >
            {index + 1}
          </div>
          <div
            style={{
              padding: "10px 14px",
              border: "1px solid #111",
              borderRadius: 18,
              background: "#fff"
            }}
          >
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                gap: 12,
                alignItems: "baseline"
              }}
            >
              <strong>{stage.label}</strong>
              <span
                style={{
                  fontSize: "0.72rem",
                  textTransform: "uppercase",
                  letterSpacing: "0.12em",
                  color: "#686868"
                }}
              >
                {statusMap[stage.status]}
              </span>
            </div>
            <p
              className="stage-description"
              style={{
                margin: "10px 0 0",
                color: "#686868",
                textTransform: "none",
                letterSpacing: 0,
                fontSize: "0.92rem",
                lineHeight: 1.55
              }}
            >
              {stage.description}
            </p>
          </div>
        </div>
      ))}
    </div>
  );
}
