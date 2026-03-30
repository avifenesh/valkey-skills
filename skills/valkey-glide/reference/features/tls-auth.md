# TLS and Authentication

Use when securing connections with encryption, certificate verification, or authentication - password-based, mutual TLS, or AWS IAM.

GLIDE supports TLS encryption, custom CA certificates, mutual TLS (mTLS), and password-based or IAM authentication across all language clients. mTLS requires GLIDE 2.3+. IAM authentication requires GLIDE 2.2+.

## Basic TLS

Enable TLS with a single flag. The server must also be configured for TLS.

### Python

```python
from glide import GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
)
client = await GlideClient.create(config)
```

### Java

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("valkey.example.com").port(6380).build())
    .useTLS(true)
    .build();
```

### Node.js

```javascript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
});
```

### Go

```go
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "valkey.example.com", Port: 6380}).
    WithUseTLS(true)
```

## Custom CA Certificates

For self-signed certificates or corporate CAs, provide custom root certificates in PEM format.

### Python

```python
from glide import (
    GlideClientConfiguration,
    AdvancedGlideClientConfiguration,
    TlsAdvancedConfiguration,
    NodeAddress,
)

# Read certificate in binary mode
with open("/path/to/ca.pem", "rb") as f:
    ca_cert = f.read()

advanced = AdvancedGlideClientConfiguration(
    tls_config=TlsAdvancedConfiguration(root_pem_cacerts=ca_cert)
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
    advanced_config=advanced,
)
```

Python `TlsAdvancedConfiguration` fields:
- `use_insecure_tls` (Optional[bool]) - bypass certificate verification (development only)
- `root_pem_cacerts` (Optional[bytes]) - custom CA certificates in PEM format
- `client_cert_pem` (Optional[bytes]) - client certificate for mTLS
- `client_key_pem` (Optional[bytes]) - client private key for mTLS

Important: `root_pem_cacerts` cannot be an empty bytes object. Use `None` to use the platform default trust store. Always read certificate files in binary mode (`"rb"`).

### Java

```java
import glide.api.models.configuration.AdvancedGlideClientConfiguration;
import glide.api.models.configuration.TlsAdvancedConfiguration;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("valkey.example.com").port(6380).build())
    .useTLS(true)
    .advancedConfiguration(
        AdvancedGlideClientConfiguration.builder()
            .tlsAdvancedConfiguration(
                TlsAdvancedConfiguration.builder()
                    .rootCertificates(caCertBytes)
                    .build()
            )
            .build()
    )
    .build();
```

### Node.js

```javascript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    tlsAdvancedConfiguration: {
        rootCertificates: caCertBuffer,  // Buffer or Uint8Array
    },
});
```

### Go

```go
import "github.com/valkey-io/valkey-glide/go/v2/config"

// Load certificates
certs, err := config.LoadRootCertificatesFromFile("/path/to/ca.pem")
if err != nil {
    log.Fatal(err)
}

tlsConfig := config.NewTlsConfiguration().WithRootCertificates(certs)
advancedConfig := config.NewAdvancedClientConfiguration().WithTlsConfiguration(tlsConfig)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "valkey.example.com", Port: 6380}).
    WithUseTLS(true).
    WithAdvancedConfiguration(advancedConfig)
```

Go `TlsConfiguration` methods:
- `WithRootCertificates(rootCerts []byte)` - custom CA certificates
- `WithClientCertificate(certPem, keyPem []byte)` - client cert/key for mTLS
- `LoadRootCertificatesFromFile(path)` - helper to read PEM file

## Hostname Verification

When TLS is enabled, the hostname in `NodeAddress` must match the server certificate's Common Name (CN) or Subject Alternative Name (SAN). This prevents man-in-the-middle attacks.

If hostname verification fails (e.g., using IP addresses or CNAMEs that don't match the certificate), the connection will be rejected. For development environments, use `use_insecure_tls=True` (Python) or equivalent to bypass verification - but never in production.

## Insecure TLS (Development Only)

Bypass certificate verification for self-signed certs or hostname mismatches:

```python
# Python
advanced = AdvancedGlideClientConfiguration(
    tls_config=TlsAdvancedConfiguration(use_insecure_tls=True)
)
```

```javascript
// Node.js
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    tlsAdvancedConfiguration: { insecure: true },
});
```

Insecure TLS requires `use_tls=True` to be set. Enabling it without TLS raises `ConfigurationError`.

## Mutual TLS (mTLS) - GLIDE 2.3+

mTLS requires both a client certificate and private key. The server verifies the client's identity in addition to the client verifying the server.

### Python

```python
with open("/path/to/client-cert.pem", "rb") as f:
    client_cert = f.read()
with open("/path/to/client-key.pem", "rb") as f:
    client_key = f.read()

advanced = AdvancedGlideClientConfiguration(
    tls_config=TlsAdvancedConfiguration(
        root_pem_cacerts=ca_cert,       # Optional: custom CA
        client_cert_pem=client_cert,     # Required for mTLS
        client_key_pem=client_key,       # Required for mTLS
    )
)
```

Both `client_cert_pem` and `client_key_pem` must be provided together. Providing one without the other raises `ConfigurationError`.

### Go

```go
tlsConfig := config.NewTlsConfiguration().
    WithRootCertificates(caCert).
    WithClientCertificate(clientCert, clientKey)
```

## Authentication

### Password-Based

```python
from glide import ServerCredentials

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    credentials=ServerCredentials(username="myuser", password="mypass"),
)
```

If `username` is not provided, the default username `"default"` is used (standard Valkey/Redis AUTH behavior).

### Java

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .credentials(
        ServerCredentials.builder()
            .username("myuser")
            .password("mypass")
            .build()
    )
    .build();
```

### Node.js

```javascript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    credentials: { username: "myuser", password: "mypass" },
});
```

### Go

```go
creds := config.NewServerCredentials("myuser", "mypass")
// Or with default username:
creds := config.NewServerCredentialsWithDefaultUsername("mypass")

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithCredentials(creds)
```

## IAM Authentication (GLIDE 2.2+)

For AWS ElastiCache or MemoryDB, GLIDE supports IAM-based authentication with automatic token refresh:

```python
from glide import ServerCredentials, IamAuthConfig, ServiceType

iam_config = IamAuthConfig(
    cluster_name="my-cluster",
    service=ServiceType.ELASTICACHE,  # or ServiceType.MEMORYDB
    region="us-east-1",
    refresh_interval_seconds=300,  # optional, defaults to 300
)

config = GlideClientConfiguration(
    addresses=[NodeAddress("my-cluster.amazonaws.com", 6379)],
    credentials=ServerCredentials(username="myIamUser", iam_config=iam_config),
    use_tls=True,
)
```

IAM and password authentication are mutually exclusive - `ServerCredentials` validates this at construction time.

## Combined TLS + Auth

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
    credentials=ServerCredentials(username="myuser", password="mypass"),
    advanced_config=AdvancedGlideClientConfiguration(
        tls_config=TlsAdvancedConfiguration(root_pem_cacerts=ca_cert)
    ),
)
```

## Related Features

- [Connection Model](../architecture/connection-model.md) - reconnection backoff, connection state preservation (credentials restored on reconnect), and permanent vs transient error classification for auth failures
- [AZ Affinity](az-affinity.md) - commonly combined with TLS in cloud deployments for secure same-zone reads
- [Logging](logging.md) - enable Debug level to diagnose TLS handshake failures and authentication errors
