######################################
# Stage: nodejs dependencies and build
FROM node:16.20.2-alpine3.18 AS builder

USER root

WORKDIR /webapp
ADD package.json .
ADD package-lock.json .
# use clean-modules on the same line as npm ci to be lighter in the cache
RUN npm ci && \
    ./node_modules/.bin/clean-modules --yes --exclude "**/*.mustache" --exclude "eslint-config-standard/.eslintrc.json"

# Adding server files
ADD server server
ADD config config

# Check quality
ADD .gitignore .gitignore
RUN npm run lint

# Cleanup /webapp/node_modules so it can be copied by next stage
RUN npm prune --production && \
    rm -rf node_modules/.cache

####################################
# Exporter using "pbm" executable from official pbm image

FROM node:16.20.2-alpine3.18

RUN apk add --no-cache unzip dumb-init

WORKDIR /webapp

COPY --from=builder /webapp/node_modules /webapp/node_modules

ADD server server
ADD config config
ADD package.json .
ADD README.md BUILD.json* ./
ADD LICENSE .

ENV NODE_ENV production

EXPOSE 8080

CMD ["dumb-init", "node", "server"]