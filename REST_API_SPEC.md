# Noosphere ROAST Server REST/SSE API

This specification is for implementing a frontend REST/SSE adapter for the
Noosphere ROAST server. The same frontend may already support the gRPC endpoint;
reuse the same Noosphere domain serializers and parsers where possible.

## Transport Model

Base URL: the REST server origin configured separately from gRPC with
`--rest-port`.

All `POST` endpoints:

- Request body is JSON.
- Request header should include `Content-Type: application/json`.
- Binary/domain objects are base64 strings of the same `.toBytes()` payloads
  used by the gRPC client.
- The server accepts standard base64 or URL-safe base64, with or without
  padding.
- Do not send gRPC/protobuf wrapper messages to REST; send the underlying
  domain bytes encoded as base64.

Success response shapes:

```json
{}
```

```json
{ "data": "<base64>" }
```

```json
{ "data": ["<base64>", "..."] }
```

Error response shapes:

```json
{ "error": "<message>" }
```

Invalid requests return HTTP `400`. Unexpected server errors return HTTP `500`
with `{ "error": "Internal server error" }`.

## Endpoints

### POST /login

Request:

```json
{
  "groupFingerprint": "<base64 bytes>",
  "participantId": "<base64 Identifier bytes>",
  "protocolVersion": 2
}
```

`protocolVersion` is optional and defaults to `2`.

Response:

```json
{ "data": "<base64 ExpirableAuthChallengeResponse bytes>" }
```

### POST /respond-to-challenge

Request:

```json
{
  "challenge": "<base64 AuthChallenge bytes>",
  "signature": "<base64 SchnorrSignature bytes>"
}
```

Response:

```json
{ "data": "<base64 LoginCompleteResponse bytes>" }
```

Use the decoded `LoginCompleteResponse.id` as the session id for later calls
and SSE.

### POST /extend-session

Request:

```json
{ "sid": "<base64 SessionID bytes>" }
```

Response:

```json
{ "data": "<base64 Expiry bytes>" }
```

### POST /dkg/new

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "signedDetails": "<base64 Signed<NewDkgDetails> bytes>",
  "commitment": "<base64 DkgPublicCommitment bytes>"
}
```

Response:

```json
{}
```

### POST /dkg/reject

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "name": "dkg-name"
}
```

Response:

```json
{}
```

### POST /dkg/commitment

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "name": "dkg-name",
  "commitment": "<base64 DkgPublicCommitment bytes>"
}
```

Response:

```json
{}
```

### POST /dkg/round2

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "name": "dkg-name",
  "commitmentSetSignature": "<base64 SchnorrSignature bytes>",
  "secrets": [
    {
      "id": "<base64 Identifier bytes>",
      "secret": "<base64 DkgEncryptedSecret bytes>"
    }
  ]
}
```

Response:

```json
{}
```

### POST /dkg/acks

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "acks": ["<base64 SignedDkgAck bytes>"]
}
```

Response:

```json
{}
```

### POST /dkg/request-acks

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "requests": ["<base64 DkgAckRequest bytes>"]
}
```

Response:

```json
{ "data": ["<base64 SignedDkgAck bytes>"] }
```

### POST /signatures/request

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "keys": ["<base64 AggregateKeyInfo bytes>"],
  "signedDetails": "<base64 Signed<SignaturesRequestDetails> bytes>",
  "commitments": ["<base64 SigningCommitment bytes>"]
}
```

Response:

```json
{}
```

### POST /signatures/reject

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "reqId": "<base64 SignaturesRequestId bytes>"
}
```

Response:

```json
{}
```

### POST /signatures/replies

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "reqId": "<base64 SignaturesRequestId bytes>",
  "replies": ["<base64 SignatureReply bytes>"]
}
```

Response when new rounds are created:

```json
{
  "type": "new_round",
  "data": "<base64 SignatureNewRoundsResponse bytes>"
}
```

Response when signatures are complete:

```json
{
  "type": "complete",
  "data": "<base64 SignaturesCompleteResponse bytes>"
}
```

Response when there is no immediate data:

```json
{
  "type": "empty",
  "data": null
}
```

### POST /secret-share

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "groupKey": "<base64 ECCompressedPublicKey bytes>",
  "secrets": [
    {
      "id": "<base64 Identifier bytes>",
      "share": "<base64 EncryptedKeyShare bytes>"
    }
  ]
}
```

Response:

```json
{ "data": ["<base64 ConstructedKeyEvent bytes>"] }
```

### POST /key-constructed/ack

Request:

```json
{
  "sid": "<base64 SessionID bytes>",
  "constructedKey": "<base64 Signed<KeyWasConstructed> bytes>"
}
```

Response:

```json
{}
```

## SSE Event Stream

Open after login:

```text
GET /sessions/<sid>/events
```

`<sid>` is the raw `SessionID.n` bytes encoded as URL-safe base64 with padding
removed.

Response headers include:

```text
content-type: text/event-stream
cache-control: no-cache
x-accel-buffering: no
```

Each SSE message:

```text
event: <event-type>
data: <base64 Event bytes>

```

Event type mapping:

```text
participant_status
new_dkg
dkg_commitment
dkg_reject
dkg_round2_share
dkg_ack
dkg_ack_request
signatures_request
signature_new_rounds
signatures_complete
signatures_failure
secret_share
constructed_key
keepalive
```

## Frontend Adapter Guidance

Implement a REST adapter with the same method surface as the existing gRPC
adapter. Most methods should be thin wrappers:

1. Serialize existing Noosphere domain objects to bytes.
2. Base64 encode those bytes into the documented JSON fields.
3. `POST` the JSON request.
4. Decode returned `data` bytes back into the same domain response classes.
5. For SSE, route by the `event` name and parse `data` as the matching Event
   bytes.

The REST transport does not replace client-side protocol logic. DKG,
signature-round, authentication, and key-sharing behavior should remain the
same as in the gRPC adapter.
