ARG FROSTY_VERSION=v3.0.0

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
ENV LD_LIBRARY_PATH="/app/build:/usr/local/lib"

EXPOSE 50051

ENTRYPOINT ["dart", "run", "noosphere_roast_server:grpc_server", "--config"]
CMD ["/config/server.yaml"]
