FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# When true: remove all Ubuntu repos and install ONLY from /opt/debs
# When false: keep Ubuntu repos (online build) and ignore /opt/debs
ARG OFFLINE_BUILD=false

# Always copy the local deb repo (harmless even in online mode)
COPY minimal-debs /opt/debs

RUN if [[ "${OFFLINE_BUILD}" == "true" ]]; then \
      echo "=== OFFLINE_BUILD=true: Using ONLY local deb repo ===" && \
      ls -lah /opt/debs && \
      test -f /opt/debs/Packages.gz && \
      \
      # Disable ALL remote repos (Ubuntu 24.04 often uses deb822 *.sources files)
      rm -f /etc/apt/sources.list && \
      rm -f /etc/apt/sources.list.d/*.list && \
      rm -f /etc/apt/sources.list.d/*.sources && \
      \
      # Local-only repo
      printf "deb [trusted=yes] file:/opt/debs ./\n" > /etc/apt/sources.list ; \
    else \
      echo "=== OFFLINE_BUILD=false: Using Ubuntu repos (online build) ===" ; \
    fi && \
    \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      cifs-utils \
      smbclient \
      samba-common-bin \
      python3-samba && \
    \
    which mount.cifs && \
    rm -rf /var/lib/apt/lists/*

COPY client.sh /client/client.sh
RUN chmod +x /client/client.sh

WORKDIR /client
ENTRYPOINT ["/client/client.sh"]