FROM node:24-alpine AS base
RUN apk add --no-cache 'zlib>=1.4-r0'

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production
EXPOSE 3001

CMD ["npm", "run", "start"]
