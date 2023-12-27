FROM node:16

COPY package.json yarn.lock ./

RUN yarn install --frozen-lockfile

COPY . .

RUN yarn build:bot

COPY package.json ./dist


CMD [ "node", "dist/script/runBot.js" ]

