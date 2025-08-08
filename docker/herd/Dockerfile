# This image combines all central components into one container, for easier
# deployment and management.
FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal essential packages that are absolutely required for herd operation
# These cannot be pre-installed on host VM as they're needed inside the container
RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext-base \
    curl \
    make \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Note: Additional dependencies can be pre-installed on the host VM if needed:
# apt-get install -y build-essential sqlite3 nginx sudo procps redis-server

# Install redis from source (to ensure availability)
ADD http://download.redis.io/redis-stable.tar.gz /tmp/redis-stable.tar.gz
RUN tar -xvzf /tmp/redis-stable.tar.gz -C /tmp
RUN cd /tmp/redis-stable && make install

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
