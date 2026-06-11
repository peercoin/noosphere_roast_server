ARG FROSTY_VERSION=v3.0.0
ARG SECP256K1_COINLIB_VERSION=0.7.0

FROM docker.io/library/debian:bookworm AS secp256k1-build
ARG SECP256K1_COINLIB_VERSION

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/peercoin/secp256k1-coinlib.git \
  && cd secp256k1-coinlib \
  && git checkout "v${SECP256K1_COINLIB_VERSION}"

WORKDIR /src/secp256k1-coinlib
RUN cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/out/install \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DSECP256K1_BUILD_SHARED=ON \
    -DSECP256K1_BUILD_STATIC=OFF \
    -DSECP256K1_BUILD_TESTS=OFF \
    -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
    -DSECP256K1_BUILD_BENCHMARK=OFF \
    -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
    -DSECP256K1_ENABLE_MODULE_EXTRAKEYS=ON \
    -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=ON \
    -DSECP256K1_ENABLE_MODULE_ECDH=ON \
    -DSECP256K1_ENABLE_MODULE_MUSIG=ON \
    -DSECP256K1_ENABLE_MODULE_ECDSA_ADAPTOR=ON \
  && cmake --build build --parallel \
  && cmake --install build \
  && mkdir -p /out \
  && cp /out/install/lib/libsecp256k1.so /out/libsecp256k1.so

FROM docker.io/library/rust:1-bookworm AS frosty-build
ARG FROSTY_VERSION

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    curl \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL \
    "https://github.com/peercoin/frosty/archive/refs/tags/${FROSTY_VERSION}.tar.gz" \
    -o frosty.tar.gz \
  && mkdir frosty \
  && tar -xzf frosty.tar.gz --strip-components=1 -C frosty \
  && rm frosty.tar.gz

WORKDIR /src/frosty/frosty_flutter/rust
RUN cargo build --release \
  && mkdir -p /out \
  && cp target/release/libfrosty_rust.so /out/libfrosty_rust.so

FROM docker.io/library/dart:stable

WORKDIR /app

# Cache dependencies before copying the rest of the source.
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

COPY --from=frosty-build /out/libfrosty_rust.so /app/build/libfrosty_rust.so
COPY --from=secp256k1-build /out/libsecp256k1.so /app/build/libsecp256k1.so
ENV LD_LIBRARY_PATH="/app/build:/usr/local/lib"

EXPOSE 50051

ENTRYPOINT ["dart", "run", "noosphere_roast_server:grpc_server", "--config"]
CMD ["/config/server.yaml"]
