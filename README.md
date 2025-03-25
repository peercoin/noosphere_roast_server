# Noosphere Server for ROAST Threshold Signatures

This is the server code for Noosphere. Servers coordinate the construction of
Taproot-compatible ROAST threshold signatures. Clients can be created using the
`noosphere_roast_client` package.

A server can be run from a given `GrpcConfig` YAML file using `dart run
noosphere_roast_server:grpc_server --config your_config_file_here.yaml`.
Alternatively a server may be created using the package as a library.

## Installation

To use the library, the underlying [frosty](https://pub.dev/packages/frosty)
package requires the associated native library which can be built from the
[frosty repository](https://github.com/peercoin/frosty) using Podman or Docker.
Linux and Android builds are supported and require placing the libraries in the
necessary location. Please see the
[frosty README.md](https://github.com/peercoin/frosty).
