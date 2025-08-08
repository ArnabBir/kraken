FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal essential packages required for container operation
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Note: Additional dependencies should be pre-installed on the host VM if needed

RUN mkdir -p -m 777 /var/log/kraken/kraken-testfs
RUN mkdir -p -m 777 /var/cache/kraken/kraken-testfs

ARG USERNAME="root"
ARG USERID="0"
RUN if [ ${USERID} != "0" ]; then useradd --uid ${USERID} ${USERNAME}; fi

COPY tools/bin/testfs/testfs /usr/bin/kraken-testfs
RUN chmod +x /usr/bin/kraken-testfs

USER ${USERNAME}

WORKDIR /etc/kraken
