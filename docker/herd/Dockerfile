# This image combines all central components into one container, for easier
# deployment and management.

FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Note: Redis should be pre-installed on the host system or mounted as a volume
# Expected tools: redis-server, nginx, sqlite3, curl
# These can be installed manually on the host VM and then:
# - Either pre-installed in the base image
# - Or mounted as volumes at runtime

# Copy pre-prepared binaries from host (run ./docker/setup-host-dependencies.sh first)
# Note: This will fail gracefully if directory doesn't exist
COPY ./docker/host-binaries/ /usr/bin/

# Create a simple curl replacement using wget if curl is not available
RUN if ! which curl >/dev/null 2>&1; then \
        echo '#!/bin/bash' > /usr/bin/curl && \
        echo 'wget -O- "$@"' >> /usr/bin/curl && \
        chmod +x /usr/bin/curl; \
    fi

# Note: All other dependencies (nginx, sqlite3) should be available in base image
# or can be added via COPY from host system if needed

RUN mkdir -p -m 777 /var/log/kraken/kraken-build-index
RUN mkdir -p -m 777 /var/log/kraken/kraken-origin
RUN mkdir -p -m 777 /var/log/kraken/kraken-proxy
RUN mkdir -p -m 777 /var/log/kraken/kraken-testfs
RUN mkdir -p -m 777 /var/log/kraken/kraken-tracker

RUN mkdir -p -m 777 /var/cache/kraken/kraken-build-index
RUN mkdir -p -m 777 /var/cache/kraken/kraken-origin
RUN mkdir -p -m 777 /var/cache/kraken/kraken-proxy
RUN mkdir -p -m 777 /var/cache/kraken/kraken-testfs
RUN mkdir -p -m 777 /var/cache/kraken/kraken-tracker

RUN mkdir -p -m 777 /var/run/kraken

ARG USERNAME="root"
ARG USERID="0"
RUN if [ ${USERID} != "0" ]; then useradd --uid ${USERID} ${USERNAME}; fi

# Allow proxy to run nginx as root.
RUN if [ ${USERID} != "0" ]; then mkdir -p /etc/sudoers.d/ && \
    echo '${USERNAME}  ALL=(root) NOPASSWD: /usr/sbin/nginx' >> /etc/sudoers.d/kraken-proxy; fi

COPY ./docker/setup_nginx.sh /tmp/setup_nginx.sh
RUN /tmp/setup_nginx.sh ${USERNAME}

COPY ./build-index/build-index /usr/bin/kraken-build-index
COPY ./origin/origin           /usr/bin/kraken-origin
COPY ./proxy/proxy             /usr/bin/kraken-proxy
COPY ./tools/bin/testfs/testfs /usr/bin/kraken-testfs
COPY ./tracker/tracker         /usr/bin/kraken-tracker

RUN chmod +x /usr/bin/kraken-build-index && \
    chmod +x /usr/bin/kraken-origin && \
    chmod +x /usr/bin/kraken-proxy && \
    chmod +x /usr/bin/kraken-testfs && \
    chmod +x /usr/bin/kraken-tracker

USER ${USERNAME}

WORKDIR /etc/kraken

COPY ./config /etc/kraken/config
COPY ./nginx/config /etc/kraken/nginx/config
COPY ./test/tls /etc/kraken/tls
