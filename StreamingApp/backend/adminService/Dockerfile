FROM node:24-alpine AS base
RUN apk add --no-cache 'zlib>=1.4-r0'

WORKDIR /app/adminService

COPY adminService/package*.json ./
RUN npm ci --omit=dev

COPY adminService/. ./
ENV NODE_ENV=production
EXPOSE 3003

CMD ["npm", "run", "start"]
