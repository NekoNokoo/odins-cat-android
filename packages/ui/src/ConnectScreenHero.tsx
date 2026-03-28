type Fact = {
  label: string;
  value: string;
};

export function ConnectScreenHero({
  eyebrow,
  title,
  description,
  facts,
  buttonLabel,
  buttonActive = false,
  buttonBusy = false,
  buttonDisabled = false,
  onButtonClick,
  error
}: {
  eyebrow: string;
  title: string;
  description: string;
  facts: Fact[];
  buttonLabel: string;
  buttonActive?: boolean;
  buttonBusy?: boolean;
  buttonDisabled?: boolean;
  onButtonClick?: () => void;
  error?: string | null;
}) {
  return (
    <section className="connection-deck">
      <div className="connection-deck__hero">
        <div className="connection-deck__copy">
          <span className="section-eyebrow">{eyebrow}</span>
          <h2 className="connection-deck__title">{title}</h2>
          <p>{description}</p>

          <div className="connection-deck__facts">
            {facts.map((fact) => (
              <div className="summary-pill" key={`${fact.label}-${fact.value}`}>
                <span>{fact.label}</span>
                <strong>{fact.value}</strong>
              </div>
            ))}
          </div>
        </div>

        <button
          className={[
            "vpn-orb",
            buttonActive ? "is-active" : "",
            buttonBusy ? "is-busy" : ""
          ].filter(Boolean).join(" ")}
          onClick={onButtonClick}
          disabled={buttonDisabled}
          type="button"
        >
          <span className="vpn-orb__ring" />
          <span className="vpn-orb__core">
            <span className="vpn-orb__label">{buttonLabel}</span>
          </span>
        </button>
      </div>

      {error ? <p className="status-banner status-error">{error}</p> : null}
    </section>
  );
}
