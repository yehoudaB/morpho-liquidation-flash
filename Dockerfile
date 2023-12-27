FROM node:20

COPY package.json yarn.lock ./

RUN yarn install --frozen-lockfile

COPY . .

RUN yarn tsc
CMD [ "node_modules/.bin/ts-node", "dist/src/index.js" ]