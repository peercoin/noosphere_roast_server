# Noosphere Server for ROAST Threshold Signatures

This is the server code for Noosphere. Servers coordinate the construction of
Taproot-compatible ROAST threshold signatures. Clients can be created using the
`noosphere_roast_client` package.

A server can be run from a given `GrpcConfig` YAML file using `dart run
noosphere_roast_server:grpc_server --config your_config_file_here.yaml`.
Alternatively a server may be created using the package as a library.

The server emits `info` logs by default. Use `--log-level` to choose one of
`trace`, `debug`, `info`, `warning`, `error`, `fatal`, or `off`:

```sh
dart run noosphere_roast_server:grpc_server \
  --config your_config_file_here.yaml \
  --log-level debug
```

REST/WebSocket can be enabled for browser clients with `--rest-port`:

```sh
dart run noosphere_roast_server:grpc_server \
  --config your_config_file_here.yaml \
  --rest-port 8080 \
  --rest-allow-origin '*'
```

`--rest-allow-origin '*'` is convenient for local testing, but production
deployments should set `--rest-allow-origin` to the exact frontend origin that
will access the REST/WebSocket API, for example `https://app.example.com`.

Use `--rest-address 0.0.0.0` when the REST/WebSocket listener must be reachable from
outside the process namespace, such as from a container port mapping. The
default REST/WebSocket bind address is `localhost`.

The REST/WebSocket API shape is documented in [REST_API_SPEC.md](REST_API_SPEC.md).

## Podman / Docker

Build the image from this repository:

```sh
podman build -t noosphere-roast-server .
```

Rebuild the image after changing local source. The Dockerfile copies this local
repository into the image with `COPY . .`, so an old image will not contain
recent CLI, logging, or REST changes.

The Dockerfile builds `libfrosty_rust.so` from `peercoin/frosty` `v3.0.0`,
matching the current `frosty` dependency, and `libsecp256k1.so` from
`peercoin/secp256k1-coinlib` `v0.7.0`, matching the current `coinlib`
dependency. If either dependency is upgraded, pass matching tags:

```sh
podman build \
  --build-arg FROSTY_VERSION=v3.0.0 \
  --build-arg SECP256K1_COINLIB_VERSION=0.7.0 \
  -t noosphere-roast-server .
```

Run the server with a mounted YAML configuration:

```sh
podman run --rm \
  -p 50051:50051 \
  -p 8080:8080 \
  -v "$PWD/config.yaml:/config/server.yaml:ro,Z" \
  noosphere-roast-server
```

The container starts both gRPC and REST/WebSocket by default. gRPC listens on the port
from the YAML config, or `50051` when `port` is omitted. REST/WebSocket listens on
container port `8080`.

Port mapping syntax is `host_port:container_port`. If the YAML config says
`port: 443`, the gRPC server listens on container port `443`, so map it with
`-p 50051:443` if clients should connect to host port `50051`. If the YAML
config omits `port` or says `port: 50051`, use `-p 50051:50051`.

The `:Z` suffix relabels the mounted config file so Podman can read it on
SELinux-enforcing hosts. Use `:z` instead if the same config file must be
shared by multiple containers.

To use a different in-container config path, pass it as the command:

```sh
podman run --rm \
  -p 50051:50051 \
  -p 8080:8080 \
  -v "$PWD/config.yaml:/app/config.yaml:ro,Z" \
  noosphere-roast-server \
  /app/config.yaml --rest-address 0.0.0.0 --rest-port 8080
```

### REST/WebSocket With CORS

For local testing, allow any browser origin and enable debug logs:

```sh
podman run --rm \
  -p 50051:50051 \
  -p 8080:8080 \
  -v "$PWD/config.yaml:/config/server.yaml:ro,Z" \
  noosphere-roast-server \
  /config/server.yaml \
  --rest-address 0.0.0.0 \
  --rest-port 8080 \
  --rest-allow-origin '*' \
  --log-level debug
```

For production, replace `'*'` with the frontend origin that loads the web app:

```sh
--rest-allow-origin https://app.example.com
```

Only one layer should emit CORS headers. If a reverse proxy such as Caddy is
already adding `Access-Control-Allow-Origin`, run the backend with
`--rest-disable-cors` instead. Otherwise browsers will reject responses with a
combined value such as `*, *`.

### Caddy Reverse Proxy

Bind container ports to localhost when Caddy runs on the same host:

```sh
podman run --rm \
  -p 127.0.0.1:50051:50051 \
  -p 127.0.0.1:8080:8080 \
  -v "$PWD/config.yaml:/config/server.yaml:ro,Z" \
  noosphere-roast-server \
  /config/server.yaml \
  --rest-address 0.0.0.0 \
  --rest-port 8080 \
  --rest-allow-origin https://app.example.com \
  --log-level info
```

REST/WebSocket on a dedicated API hostname:

```caddyfile
api.example.com {
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}
```

Do not add CORS headers in both Caddy and the backend. Either let the backend
handle CORS with `--rest-allow-origin`, or let Caddy handle it and run the
backend with `--rest-disable-cors`.

If the browser frontend is served from the same hostname and REST is under a
prefix, strip the prefix before proxying:

```caddyfile
app.example.com {
	handle_path /api/noosphere/* {
		reverse_proxy 127.0.0.1:8080 {
			flush_interval -1
		}
	}

	root * /srv/app
	file_server
}
```

### Ngrok For REST/WebSocket Testing

Expose the REST/WebSocket port, not the gRPC port:

```sh
ngrok http 8080
```

Use the printed HTTPS URL as the REST base URL in the frontend. The websocket
event stream will be under:

```text
wss://<ngrok-host>/sessions/<sid>/events
```

### Logging

Use `--log-level debug` when diagnosing frontend connectivity:

```sh
--log-level debug
```

At `info`, the server logs lifecycle and coordinator state changes such as
startup, auth challenges, participant login/logout, DKG requests, signature
completion, and shutdown.

At `debug`, the gRPC transport also logs request receipt/completion and event
stream lifecycle, for example:

```text
gRPC login received
gRPC login completed
gRPC fetchEventStream opened for participant ...
```

If shared coordinator logs appear but no `gRPC ... received` logs appear while
running with `--log-level debug`, the frontend is probably using REST or the
gRPC request is not reaching this container. Check the configured client port,
container port mapping, firewall, and any reverse proxy.

The same commands also work with Docker by replacing `podman` with `docker`.

## Installation

To use the library, the underlying [frosty](https://pub.dev/packages/frosty)
package requires the associated native library which can be built from the
[frosty repository](https://github.com/peercoin/frosty) using Podman or Docker.
Please see the [frosty README.md](https://github.com/peercoin/frosty).
