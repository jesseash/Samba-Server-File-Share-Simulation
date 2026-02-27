FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Copy local Samba .deb files
COPY debs /opt/debs

# Install Samba from local .deb files only
RUN dpkg -i /opt/debs/*.deb || true && \
    apt-get update && \
    apt-get install -f -y && \
    rm -rf /var/lib/apt/lists/*

# Symlink full_audit module to correct location
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
