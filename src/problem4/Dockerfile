FROM node:24.14.0-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
COPY src/problem3/api/package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --chown=node:node src/problem3/api/src ./src
ARG RELEASE_SHA=local
ENV RELEASE_SHA=$RELEASE_SHA
LABEL org.opencontainers.image.revision=$RELEASE_SHA
USER node
EXPOSE 3000
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=6 CMD ["node", "-e", "fetch('http://127.0.0.1:3000/api/health').then(async r=>{const h=await r.json();if(!r.ok||h.status!=='ok'||!h.postgres.ok||!h.redis.ok||h.release!==process.env.RELEASE_SHA)process.exit(1)}).catch(()=>process.exit(1))"]
CMD ["node", "src/index.js"]
