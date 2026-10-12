FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src
RUN mkdir -p /data && chown node:node /data
USER node
ENV DATA_DIR=/data PORT=8080
EXPOSE 8080
CMD ["node", "src/index.js"]
