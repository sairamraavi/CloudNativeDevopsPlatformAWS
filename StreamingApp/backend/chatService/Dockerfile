FROM node:24-alpine AS base
RUN apk add --no-cache 'zlib>=1.4-r0'

WORKDIR /app/chatService

COPY chatService/package*.json ./
RUN npm ci --omit=dev

COPY chatService/. ./
ENV NODE_ENV=production
EXPOSE 3004

CMD ["npm", "run", "start"]
