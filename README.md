# Noosphere Server for ROAST Threshold Signatures

This is the server code for Noosphere. Servers coordinate the construction of
Taproot-compatible ROAST threshold signatures. Clients can be created using the
`noosphere_roast_client` package.

A server can be run from a given `GrpcConfig` YAML file using `dart run
noosphere_roast_server:grpc_server --config your_config_file_here.yaml`.
Alternatively a server may be created using the package as a library.

## Podman / Docker

Build the image from this repository:

```sh
podman build -t noosphere-roast-server .
```

The Dockerfile builds `libfrosty_rust.so` from `peercoin/frosty` `v3.0.0`,
matching the current `frosty` dependency. If the dependency is upgraded, pass a
matching tag:

```sh
podman build --build-arg FROSTY_VERSION=v3.0.0 -t noosphere-roast-server .
```

Run the server with a mounted YAML configuration:

```sh
podman run --rm \
  -p 50051:50051 \
  -v "$PWD/config.yaml:/config/server.yaml:ro,Z" \
  noosphere-roast-server
```

The `:Z` suffix relabels the mounted config file so Podman can read it on
SELinux-enforcing hosts. Use `:z` instead if the same config file must be
shared by multiple containers.

To use a different in-container config path, pass it as the command:

```sh
podman run --rm \
  -p 50051:50051 \
  -v "$PWD/config.yaml:/app/config.yaml:ro,Z" \
  noosphere-roast-server /app/config.yaml
```

The image builds the `frosty` native library during the container build and
copies `libfrosty_rust.so` into `/app/build`.

The same commands also work with Docker by replacing `podman` with `docker`.

## Installation

To use the library, the underlying [frosty](https://pub.dev/packages/frosty)
package requires the associated native library which can be built from the
[frosty repository](https://github.com/peercoin/frosty) using Podman or Docker.
Please see the [frosty README.md](https://github.com/peercoin/frosty).
