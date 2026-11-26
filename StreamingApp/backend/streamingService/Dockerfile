FROM node:24-alpine AS base
RUN apk add --no-cache 'zlib>=1.4-r0'

WORKDIR /app/streamingService

COPY streamingService/package*.json ./
RUN npm ci --omit=dev

COPY streamingService/. ./
ENV NODE_ENV=production
EXPOSE 3002

CMD ["npm", "run", "start"]
