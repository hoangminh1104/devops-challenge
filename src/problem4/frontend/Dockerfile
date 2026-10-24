FROM node:24.14.0-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY app.js build.mjs ./
ARG RELEASE_SHA=0000000000000000000000000000000000000000
RUN RELEASE_SHA=$RELEASE_SHA npm run build
FROM nginx:1.28.3-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
