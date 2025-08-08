FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal essential packages required for container operation  
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Note: Additional dependencies should be pre-installed on the host VM if needed:
# Manual installation required: apt-get install -y sqlite3 nginx

RUN mkdir -p -m 777 /var/log/kraken/kraken-origin
RUN mkdir -p -m 777 /var/cache/kraken/kraken-origin
RUN mkdir -p -m 777 /var/run/kraken

ARG USERNAME="root"
ARG USERID="0"
RUN if [ ${USERID} != "0" ]; then useradd --uid ${USERID} ${USERNAME}; fi

COPY ./docker/setup_nginx.sh /tmp/setup_nginx.sh
RUN /tmp/setup_nginx.sh ${USERNAME}

COPY ./origin/origin /usr/bin/kraken-origin
COPY ./config /etc/kraken/config
COPY ./nginx/config /etc/kraken/nginx/config
COPY ./localdb/migrations /etc/kraken/localdb/migrations
COPY ./test/tls /etc/kraken/tls

RUN chmod +x /usr/bin/kraken-origin

USER ${USERNAME}

WORKDIR /etc/kraken
