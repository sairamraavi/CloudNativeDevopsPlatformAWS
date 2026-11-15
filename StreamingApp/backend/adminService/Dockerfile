FROM node:24-alpine AS base
RUN apk upgrade --no-cache zlib

WORKDIR /app/adminService

COPY adminService/package*.json ./
RUN npm ci --omit=dev

COPY adminService/. ./
ENV NODE_ENV=production
EXPOSE 3003

CMD ["npm", "run", "start"]
