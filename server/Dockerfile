# ---- build 阶段：装依赖、编译 TS ----
# better-sqlite3 是原生模块：缺预编译产物时需编译，故带上工具链。
# 国内拉基础镜像慢的话，可换镜像源（见 docs/deployment.md）。
FROM node:22-bookworm-slim AS build
WORKDIR /app

# 工具链兜底（better-sqlite3 无预编译产物时编译用）
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

# 先拷清单以利用层缓存；registry 可用 --build-arg 覆盖（如 npmmirror）
ARG NPM_REGISTRY=https://registry.npmjs.org
COPY package.json package-lock.json ./
RUN npm ci --registry=$NPM_REGISTRY

COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# 只留生产依赖（含 better-sqlite3 已编译的二进制）
RUN npm prune --omit=dev

# ---- runtime 阶段：瘦身，只带产物 ----
FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

# SQLite 数据文件目录（docker-compose 用命名卷挂载到这里）
RUN mkdir -p /app/data && chown node:node /app/data

ENV PORT=3000 \
    DB_PATH=/app/data/chat.db

EXPOSE 3000
USER node
CMD ["node", "dist/index.js"]
