FROM node:22-bookworm-slim

ARG OPENAI_CODEX_VERSION=0.129.0
ARG ANTHROPIC_CLAUDE_CODE_VERSION=2.1.133
ARG OPENCODE_VERSION=1.14.49

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates sqlite3 util-linux \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
  @openai/codex@${OPENAI_CODEX_VERSION} \
  @anthropic-ai/claude-code@${ANTHROPIC_CLAUDE_CODE_VERSION} \
  opencode-ai@${OPENCODE_VERSION}

WORKDIR /app
COPY package*.json ./
COPY src ./src

ENV NODE_ENV=production
ENV PORT=8080

# Drop privileges: the runner only needs to serve HTTP and shell out to the
# provider CLIs, so it runs as the stock `node` user instead of root.
RUN chown -R node:node /app
USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]

CMD ["node", "src/server.mjs"]
