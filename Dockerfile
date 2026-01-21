##########################
FROM node:24.13.0-alpine3.23 AS base

WORKDIR /webapp
ENV NODE_ENV=production

##########################
FROM base AS package-strip

RUN apk add --no-cache jq moreutils
ADD package.json package-lock.json ./
# remove version from manifest for better caching when building a release
RUN jq '.version="build"' package.json | sponge package.json
RUN jq '.version="build"' package-lock.json | sponge package-lock.json

##########################
FROM base AS installer

RUN apk add --no-cache python3 make g++ git jq moreutils
RUN npm i -g clean-modules@3.1.1
COPY --from=package-strip /webapp/package.json package.json
COPY --from=package-strip /webapp/package-lock.json package-lock.json
RUN npm ci --omit=dev --omit=optional --no-audit --no-fund && npx clean-modules --yes

######################################
FROM base AS main

COPY --from=installer /webapp/node_modules node_modules
ADD /server server
ADD package.json README.md LICENSE BUILD.json* ./

USER node
EXPOSE 9090

CMD ["node", "server/index.ts"]
