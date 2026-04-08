import type { ReactNode } from "react";

export function AppShell({
  kicker,
  title,
  titleAccessory,
  subtitle,
  headerAction,
  dragRegion = false,
  compactHeader = false,
  children
}: {
  kicker?: string;
  title: string;
  titleAccessory?: ReactNode;
  subtitle?: string;
  headerAction?: ReactNode;
  dragRegion?: boolean;
  compactHeader?: boolean;
  children: ReactNode;
}) {
  return (
    <main className="shell">
      <section className="topbar">
        {compactHeader ? (
          <div className="topbar-copy topbar-copy--compact">
            <div className="topbar-head topbar-head--compact">
              <div
                className={`topbar-title${titleAccessory ? " topbar-title--with-accessory" : ""}`}
                {...(dragRegion ? { "data-tauri-drag-region": true } : {})}
              >
                <div className="topbar-title-row">
                  <h1>{title}</h1>
                  {titleAccessory ? <div className="topbar-title-accessory">{titleAccessory}</div> : null}
                </div>
              </div>
              {headerAction ? <div className="topbar-action">{headerAction}</div> : null}
            </div>
          </div>
        ) : (
          <div className="topbar-copy">
            {dragRegion ? <div className="window-drag-region" data-tauri-drag-region /> : null}
            <div className="topbar-head">
              {kicker ? <span className="kicker">{kicker}</span> : <span />}
              {headerAction}
            </div>
            <h1>{title}</h1>
            {subtitle ? <p>{subtitle}</p> : null}
          </div>
        )}
      </section>

      <section className="workspace">{children}</section>
    </main>
  );
}
