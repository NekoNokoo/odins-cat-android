"use client";

import { useEffect, useState } from "react";

const introDurationMs = 3600;
const reducedMotionDurationMs = 120;

export function LaunchIntro() {
  const [visible, setVisible] = useState(true);
  const [animating, setAnimating] = useState(false);

  useEffect(() => {
    const prefersReducedMotion =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const duration = prefersReducedMotion
      ? reducedMotionDurationMs
      : introDurationMs;
    let frameId = 0;
    frameId = window.requestAnimationFrame(() => {
      setAnimating(true);
    });
    const timer = window.setTimeout(() => {
      setVisible(false);
    }, duration);

    return () => {
      window.cancelAnimationFrame(frameId);
      window.clearTimeout(timer);
    };
  }, []);

  if (!visible) {
    return null;
  }

  return (
    <div
      className={`launch-intro${animating ? " is-animating" : ""}`}
      aria-hidden="true"
    >
      <div className="launch-intro__backdrop" />
      <div className="launch-intro__cat-stage">
        <div className="launch-intro__cat-motion">
          <div className="launch-intro__glow" />
          <img
            className="launch-intro__cat-mark-img"
            src="/odins-cat-launch-mark.svg"
            alt=""
            aria-hidden="true"
          />
        </div>
      </div>
    </div>
  );
}
