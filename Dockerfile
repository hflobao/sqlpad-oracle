# Need to remote into this image and debug some flow? 
# docker run -it --rm node:12.22.1-alpine3.12 /bin/ash
FROM node:lts-buster AS build
ARG ODBC_ENABLED=true
RUN apt-get update && apt-get install -y \
    python3 make g++ python3-dev  \
    && ( \
    if [ "$ODBC_ENABLED" = "true" ] ; \
    then \
    echo "Installing ODBC build dependencies." 1>&2 ;\
    apt-get install -y unixodbc-dev ;\
    npm install -g node-gyp ;\
    fi\
    ) \
    && rm -rf /var/lib/apt/lists/*
RUN npm config set python /usr/bin/python3

WORKDIR /sqlpad

# By copying just the package files and installing node layers, 
# we can take advantage of caching
# SQLPad is really 3 node projects though
# * root directory for linting
# * client/ for web front end
# * server/ for server (and what eventually holds built front end)
COPY ./package* ./
COPY ./client/package* ./client/
COPY ./server/package* ./server/
COPY ./yarn* ./
COPY ./client/yarn* ./client/
COPY ./server/yarn* ./server/

# Install dependencies
RUN yarn
WORKDIR /sqlpad/client
RUN yarn
WORKDIR /sqlpad/server
RUN yarn
WORKDIR /sqlpad

# Copy rest of the project into docker
COPY . .

# Build front-end and copy files into server public dir
RUN npm run build --prefix client && \
    rm -rf server/public && \
    mkdir server/public && \
    cp -r client/build/* server/public

# Build test db used for dev, debugging and running tests
RUN node server/generate-test-db-fixture.js

# Run tests and linting to validate build
ENV SKIP_INTEGRATION true
RUN npm run test --prefix server
RUN npm run lint

# Remove any dev dependencies from server
# We don't care about root or client directories 
# as they are not going to be copied to next stage
WORKDIR /sqlpad/server
RUN npm prune --production

# Download & Unpack oracle stuff in a seperate image this reduces the amount of downloads if you change the script around
RUN apt-get install -y unzip wget \
    && echo "Downloading Oracle Instant Client lite and ODBC drivers." 1>&2 \
    && wget -q -O /opt/client.zip https://download.oracle.com/otn_software/linux/instantclient/211000/instantclient-basiclite-linux.x64-21.1.0.0.0.zip \
    && wget -q -O /opt/odbc.zip https://download.oracle.com/otn_software/linux/instantclient/211000/instantclient-odbc-linux.x64-21.1.0.0.0.zip
    
RUN cd /opt \
    && unzip -q client.zip \
    && unzip -q odbc.zip \
    && rm client.zip odbc.zip

# Start another stage with a fresh node
# Copy the server directory that has all the necessary node modules + front end build
FROM node:lts-buster-slim as bundle
ARG ODBC_ENABLED=true

# Create a directory for the hooks and optionaly install ODBC
RUN mkdir -p /etc/docker-entrypoint.d \
    && apt-get update && apt-get install -y wget \
    && ( \
    if [ "$ODBC_ENABLED" = "true" ] ; \
    then \
    echo "Installing ODBC runtime dependencies." 1>&2 ;\
    apt-get install -y unixodbc libaio1 odbcinst libodbc1 ;\
    touch /etc/odbcinst.ini ;\
    fi\
    ) \
    && rm -rf /var/lib/apt/lists/* 

WORKDIR /usr/app
COPY --from=build /sqlpad/docker-entrypoint /
COPY --from=build /sqlpad/server .
COPY --from=build /opt /opt

# Setup some oracle variables
ENV TNS_ADMIN=/opt/instantclient_21_1/network/admin
ENV LD_LIBRARY_PATH=/opt/instantclient_21_1
# Install the driver for oracle into ODBC.
RUN cd /opt/instantclient_21_1 && /opt/instantclient_21_1/odbc_update_ini.sh /

ENV NODE_ENV production
ENV SQLPAD_DB_PATH /var/lib/sqlpad
ENV SQLPAD_PORT 3000
EXPOSE 3000
ENTRYPOINT ["/docker-entrypoint"]

# Things to think about for future docker builds
# Perhaps add a healthcheck?
# Should nginx be used to front sqlpad? << No. you can always add an LB/nginx on top of this with compose or other tools when needed.

RUN ["chmod", "+x", "/docker-entrypoint"]
WORKDIR /var/lib/sqlpad
