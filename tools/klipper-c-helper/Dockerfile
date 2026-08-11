FROM debian:bookworm-slim

ARG TOOLCHAIN_ARCHIVE=mips32r5el--glibc--bleeding-edge-2018.11-1.tar.bz2
ARG TOOLCHAIN_SHA256=633ef37e8eb96535e2bf6e708b82d5016390676698a8da4b7b00a7cece5dc328
ARG TOOLCHAIN_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/mips32r5el/tarballs/${TOOLCHAIN_ARCHIVE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bzip2 \
        ca-certificates \
        curl \
        file \
        libstdc++6 \
        python3 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "${TOOLCHAIN_URL}" -o "/tmp/${TOOLCHAIN_ARCHIVE}" \
    && echo "${TOOLCHAIN_SHA256}  /tmp/${TOOLCHAIN_ARCHIVE}" | sha256sum -c - \
    && mkdir -p /opt/mips-toolchain \
    && tar -xjf "/tmp/${TOOLCHAIN_ARCHIVE}" -C /opt/mips-toolchain \
    && rm "/tmp/${TOOLCHAIN_ARCHIVE}"

ENV TOOLCHAIN_ROOT=/opt/mips-toolchain/mips32r5el--glibc--bleeding-edge-2018.11-1
ENV CROSS_PREFIX=/opt/mips-toolchain/mips32r5el--glibc--bleeding-edge-2018.11-1/bin/mipsel-buildroot-linux-gnu-
ENV SYSROOT=/opt/mips-toolchain/mips32r5el--glibc--bleeding-edge-2018.11-1/mipsel-buildroot-linux-gnu/sysroot

COPY build-c-helper.sh /usr/local/bin/build-klipper-c-helper

ENTRYPOINT ["/usr/local/bin/build-klipper-c-helper"]
