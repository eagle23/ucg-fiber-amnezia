FROM debian:bullseye

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-aarch64-linux-gnu \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    kmod \
    git \
    wget \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Cache kernel source download in Docker layer
ARG KERNEL_VERSION=5.4.213
RUN wget -q "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz" \
    && tar xf "linux-${KERNEL_VERSION}.tar.xz" \
    && rm "linux-${KERNEL_VERSION}.tar.xz"
