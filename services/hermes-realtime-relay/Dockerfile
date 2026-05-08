FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json* tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build \
  && rm -f lib/*.test.js \
  && npm prune --omit=dev

FROM node:22-slim
WORKDIR /app
COPY package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/lib ./lib
ENV NODE_ENV=production
CMD ["node", "lib/server.js"]
