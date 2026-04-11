"use client";

import { useEffect, useRef, useState } from "react";

const introDurationMs = 2200;
const reducedMotionDurationMs = 120;

export function LaunchIntro() {
  const [visible, setVisible] = useState(true);
  const [animating, setAnimating] = useState(false);
  const [videoReady, setVideoReady] = useState(false);
  const hideTimerRef = useRef<number | null>(null);
  const revealTimerRef = useRef<number | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);

  const revealVideo = () => {
    setVideoReady((current) => current || true);
  };

  useEffect(() => {
    return () => {
      if (hideTimerRef.current !== null) {
        window.clearTimeout(hideTimerRef.current);
      }
      if (revealTimerRef.current !== null) {
        window.clearTimeout(revealTimerRef.current);
      }
    };
  }, []);

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
    hideTimerRef.current = window.setTimeout(() => {
      setVisible(false);
    }, duration);

    return () => {
      window.cancelAnimationFrame(frameId);
      if (hideTimerRef.current !== null) {
        window.clearTimeout(hideTimerRef.current);
      }
      if (revealTimerRef.current !== null) {
        window.clearTimeout(revealTimerRef.current);
      }
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
          <video
            ref={videoRef}
            className={`launch-intro__video${videoReady ? " is-ready" : ""}`}
            src="/cat-vpn-launch-9x16.mp4"
            autoPlay
            muted
            playsInline
            preload="auto"
            disablePictureInPicture
            controlsList="nodownload nofullscreen noremoteplayback"
            onPlaying={() => {
              const video = videoRef.current;
              if (
                video &&
                "requestVideoFrameCallback" in video &&
                typeof video.requestVideoFrameCallback === "function"
              ) {
                video.requestVideoFrameCallback(() => {
                  revealVideo();
                });
                return;
              }
              if (revealTimerRef.current !== null) {
                window.clearTimeout(revealTimerRef.current);
              }
              revealTimerRef.current = window.setTimeout(() => {
                revealVideo();
              }, 90);
            }}
            onLoadedData={() => {
              if (videoReady) {
                return;
              }
              if (revealTimerRef.current !== null) {
                window.clearTimeout(revealTimerRef.current);
              }
              revealTimerRef.current = window.setTimeout(() => {
                revealVideo();
              }, 90);
            }}
          />
        </div>
      </div>
    </div>
  );
}
