# LegionIO Security

## Authentication

### Kerberos + Vault
LegionIO authenticates to HashiCorp Vault using Kerberos (SPNEGO). On macOS or Linux machines joined to Active Directory, the existing Kerberos ticket is used — no password entry needed. The SPNEGO token is sent as an HTTP Authorization header to Vault's Kerberos auth backend, which returns a Vault token. Token renewal runs in a background thread at 75% TTL.

### JWT Authentication
The REST API uses JWT Bearer auth. Tokens are validated against JWKS endpoints. Skip paths exist for health and readiness checks.

### mTLS
Optional mutual TLS for internal communications. Vault PKI issues certificates, and a background thread rotates them at 50% TTL. Feature-flagged via `security.mtls.enabled`.

## Secrets Management

All secrets are stored in HashiCorp Vault, never on disk. Config files reference secrets using `vault://` URIs that are resolved at runtime. Environment variable fallback is supported via `env://` URIs.

Example: `"bearer_token": "vault://secret/data/llm/bedrock#bearer_token"`

## RBAC

Optional role-based access control using Vault-style flat policies. Policies map identities to allowed actions on resources. Enforced at the API middleware layer and in the LLM pipeline.

## HIPAA PHI Compliance

- **PHI Tagging**: Metadata classification for sensitive data
- **PHI Access Logging**: Audit trail via Legion::Audit for all PHI access
- **PHI Erasure**: Crypto-erasure orchestration via Crypt::Erasure + Cache purge
- **PHI TTL Cap**: legion-cache enforces maximum TTL for PHI-tagged data
- **Redaction**: Automatic PII/PHI redaction in all log output via legion-logging

All PHI features are off by default and enabled via configuration.

## Audit

- Tamper-evident hash chain for audit entries
- 7-year tiered retention (hot -> warm -> cold storage)
- SIEM export for Splunk/ELK ingestion
- Queryable via CLI (`legion audit`) and REST API

## Network Security

- No public IPs or ingress in production deployments
- TLS required on all connections (Optum-sanctioned CAs only in UHG deployments)
- Rate limiting middleware with per-IP/agent/tenant tiers
- Request body size limits (1MB max)
