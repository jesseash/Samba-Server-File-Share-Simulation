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
      samba && \
    \
    rm -rf /var/lib/apt/lists/*

# Symlink full_audit module to correct location
COPY full_audit.so /usr/lib/x86_64-linux-gnu/samba/vfs/full_audit.so
RUN mkdir -p /usr/lib/samba/vfs && \
    ln -s /usr/lib/x86_64-linux-gnu/samba/vfs/full_audit.so /usr/lib/samba/vfs/full_audit.so

# Create internal privileged UNIX user
RUN useradd -M -s /usr/sbin/nologin simadmin

# Create Samba user with empty password
RUN (echo ""; echo "") | smbpasswd -a -s simadmin

# Create share directory and give ownership to simadmin
RUN mkdir -p /data/samba && \
    chown -R simadmin:simadmin /data/samba

# Copy configs
COPY smb.conf /etc/samba/smb.conf
COPY username.map /etc/samba/username.map

RUN chmod 644 /etc/samba/smb.conf /etc/samba/username.map

EXPOSE 137/udp 138/udp 139/tcp 445/tcp

ENTRYPOINT ["smbd", "-F", "--no-process-group", "--configfile=/etc/samba/smb.conf"]
