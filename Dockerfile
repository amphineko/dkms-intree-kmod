ARG FEDORA_VERSION=latest
FROM docker.io/library/fedora:${FEDORA_VERSION}

ARG IMAGE_VERSION=0.1.0

LABEL org.opencontainers.image.title="dkms-intree-kmod" \
      org.opencontainers.image.description="Build one in-tree Linux kernel module against a mounted kernel-devel tree" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

RUN dnf -y install \
        bash \
        bc \
        binutils \
        bison \
        ca-certificates \
        dkms \
        dwarves \
        elfutils-libelf-devel \
        findutils \
        flex \
        gcc \
        gcc-c++ \
        grep \
        git \
        kmod \
        kernel-srpm-macros \
        make \
        openssl-devel \
        patch \
        perl \
        python3-rpm-macros \
        rpm-build \
        sed \
        tar \
        util-linux \
        which \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY dkms.conf /etc/dkms-intree-kmod/dkms.conf
COPY docker-entrypoint.sh /usr/local/bin/dkms-intree-kmod
RUN chmod 0755 /usr/local/bin/dkms-intree-kmod

ENTRYPOINT ["/usr/local/bin/dkms-intree-kmod"]
