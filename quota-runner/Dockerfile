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

CMD ["node", "src/server.mjs"]
