######################################
# Stage: nodejs dependencies and build
FROM registry.access.redhat.com/ubi8/nodejs-16 AS builder

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

FROM registry.access.redhat.com/ubi8/nodejs-16-minimal

WORKDIR /webapp

COPY --from=builder /webapp/node_modules /webapp/node_modules
COPY --from=percona/percona-backup-mongodb:1.8.1 /usr/bin/pbm /usr/bin/pbm-agent /usr/bin/pbm-speed-test /usr/bin/

ADD server server
ADD config config
ADD package.json .
ADD README.md BUILD.json* ./
ADD LICENSE .

ENV NODE_ENV production

EXPOSE 8080

CMD ["node", "server"]