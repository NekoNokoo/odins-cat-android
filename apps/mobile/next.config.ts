import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  typedRoutes: true,
  output: "export",
  assetPrefix: "./",
  typescript: {
    ignoreBuildErrors: true
  }
};

export default nextConfig;
