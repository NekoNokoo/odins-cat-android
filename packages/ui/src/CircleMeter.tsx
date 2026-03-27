export function CircleMeter({
  value,
  label,
  caption
}: {
  value: number;
  label: string;
  caption: string;
}) {
  const bounded = Math.max(0, Math.min(100, value));
  const angle = (bounded / 100) * 360;

  return (
    <div
      style={{
        width: "100%",
        display: "grid",
        justifyItems: "center",
        gap: 18
      }}
    >
      <div
        aria-label={label}
        style={{
          width: 240,
          height: 240,
          borderRadius: "50%",
          display: "grid",
          placeItems: "center",
          background: `conic-gradient(#111 ${angle}deg, #ecece7 ${angle}deg 360deg)`,
          border: "1.5px solid #111"
        }}
      >
        <div
          style={{
            width: 168,
            height: 168,
            borderRadius: "50%",
            background: "#fff",
            border: "1.5px solid #111",
            display: "grid",
            placeItems: "center",
            textAlign: "center",
            padding: 20
          }}
        >
          <div>
            <div
              style={{
                fontSize: "3.6rem",
                lineHeight: 1,
                letterSpacing: "-0.08em"
              }}
            >
              {bounded}
            </div>
            <div
              style={{
                marginTop: 8,
                fontSize: "0.72rem",
                textTransform: "uppercase",
                letterSpacing: "0.14em"
              }}
            >
              {label}
            </div>
          </div>
        </div>
      </div>
      <p
        style={{
          maxWidth: 240,
          margin: 0,
          textAlign: "center",
          color: "#686868",
          lineHeight: 1.5
        }}
      >
        {caption}
      </p>
    </div>
  );
}

