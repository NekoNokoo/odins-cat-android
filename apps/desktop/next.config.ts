import path from "node:path";

import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  assetPrefix: "./",
  turbopack: {
    root: path.join(__dirname, "../..")
  },
  experimental: {
    webpackBuildWorker: false,
    workerThreads: false
  },
  typescript: {
    ignoreBuildErrors: true
  }
};

export default nextConfig;
