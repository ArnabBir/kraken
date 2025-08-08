FROM docker.phonepe.com/ubuntu

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Note: Dependencies should be pre-installed on the host VM
# Manual installation required: apt-get install -y curl

RUN mkdir -p -m 777 /var/log/kraken/kraken-testfs
RUN mkdir -p -m 777 /var/cache/kraken/kraken-testfs

ARG USERNAME="root"
ARG USERID="0"
RUN if [ ${USERID} != "0" ]; then useradd --uid ${USERID} ${USERNAME}; fi

COPY tools/bin/testfs/testfs /usr/bin/kraken-testfs
RUN chmod +x /usr/bin/kraken-testfs

USER ${USERNAME}

WORKDIR /etc/kraken
