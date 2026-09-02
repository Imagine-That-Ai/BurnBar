FROM node:26-bookworm-slim@sha256:367679cf9792759492a486e4aa4b421764d71a9546a6dae8aab81a99eb797b3e AS build
WORKDIR /repo

# Build from the repository root context. hosted-mcp depends on local
# file:../../packages/* packages and prebuild scripts under ../../scripts.
COPY packages/entitlements/package*.json packages/entitlements/
COPY packages/signal-envelope-contracts/package*.json packages/signal-envelope-contracts/
COPY services/hosted-mcp/package*.json services/hosted-mcp/
COPY scripts/build-entitlements.sh scripts/build-signal-envelope-contracts.sh scripts/
COPY packages/entitlements/tsconfig.json packages/entitlements/
COPY packages/entitlements/src packages/entitlements/src
COPY packages/signal-envelope-contracts/tsconfig.json packages/signal-envelope-contracts/
COPY packages/signal-envelope-contracts/src packages/signal-envelope-contracts/src
COPY services/hosted-mcp/tsconfig.json services/hosted-mcp/
COPY services/hosted-mcp/src services/hosted-mcp/src

RUN npm ci --prefix services/hosted-mcp
RUN npm --prefix services/hosted-mcp run build

FROM node:26-bookworm-slim@sha256:367679cf9792759492a486e4aa4b421764d71a9546a6dae8aab81a99eb797b3e
ENV NODE_ENV=production
WORKDIR /repo

COPY packages/entitlements/package*.json packages/entitlements/
COPY --from=build /repo/packages/entitlements/lib packages/entitlements/lib
COPY packages/signal-envelope-contracts/package*.json packages/signal-envelope-contracts/
COPY --from=build /repo/packages/signal-envelope-contracts/lib packages/signal-envelope-contracts/lib
COPY services/hosted-mcp/package*.json services/hosted-mcp/

RUN npm ci --prefix services/hosted-mcp --omit=dev
COPY --from=build /repo/services/hosted-mcp/lib services/hosted-mcp/lib

WORKDIR /repo/services/hosted-mcp
USER node
EXPOSE 8080
CMD ["node", "lib/server.js"]
