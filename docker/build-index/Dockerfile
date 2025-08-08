FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal essential packages required for container operation
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Note: Additional dependencies should be pre-installed on the host VM if needed:
# Manual installation required: apt-get install -y nginx

RUN mkdir -p -m 777 /var/log/kraken/kraken-build-index
RUN mkdir -p -m 777 /var/cache/kraken/kraken-build-index
RUN mkdir -p -m 777 /var/run/kraken

ARG USERNAME="root"
ARG USERID="0"
RUN if [ ${USERID} != "0" ]; then useradd --uid ${USERID} ${USERNAME}; fi

COPY ./docker/setup_nginx.sh /tmp/setup_nginx.sh
RUN /tmp/setup_nginx.sh ${USERNAME}

COPY ./build-index/build-index /usr/bin/kraken-build-index
COPY ./config /etc/kraken/config
COPY ./nginx/config /etc/kraken-build-index/nginx/config
COPY ./localdb/migrations /etc/kraken-build-index/localdb/migrations
COPY ./test/tls /etc/kraken/tls

RUN chmod +x /usr/bin/kraken-build-index

USER ${USERNAME}

WORKDIR /etc/kraken-build-index
