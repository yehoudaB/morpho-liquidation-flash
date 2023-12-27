FROM node:20.5.1-alpine
WORKDIR /
COPY . .
RUN npm install 
RUN npm run build



CMD [ "node", "dist/script/runBot.js" ]

