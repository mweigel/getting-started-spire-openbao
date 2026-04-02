# Repository Now Maintained by ControlPlane

This repository is now maintained by [ControlPlane](https://control-plane.io) under [controlplaneio/getting-started-spire-openbao](https://github.com/controlplaneio/getting-started-spire-openbao). Any updates and improvements will be available there.

# Getting Started with Spire and OpenBao

A simple demonstration of how SPIFFE and Spire can be used to issue [SPIFFE Verifiable Identity Documents (SVIDs)](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#spiffe-verifiable-identity-document-svid), in this case JWTs, that can then be used to authenticate to OpenBao in order to access other secret material. This tutorial is purposefully kept very simple and is designed as a starting point for people that want to begin learning about OpenBao, SPIFFE and Spire. The Bash snippets can be copied and pasted to create a minimal working installation on Linux. A more full-featured tutorial based on a Kubernetes deployment is available [here](https://spiffe.io/docs/latest/keyless/vault/readme/).

# Goals
- Create a simple Spire deployment including the OIDC provider
- Configure OpenBao for JWT authentication
- Retrieve a JWT from the [Spire agent workload API](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#spiffe-workload-api) and use it to authenticate to OpenBao

# Prerequisites
The following binaries must be installed in your $PATH.
- bao
- spire-agent
- spire-server
- oidc-discovery-provider
- cfssl
- cfssljson
- jq

They are available from the links below or from your OS's package manager.
- [OpenBao](https://github.com/openbao/openbao)
- [Spire](https://github.com/spiffe/spire)
- [CFSSL](https://github.com/cloudflare/cfssl)
- [Jq](https://github.com/jqlang/jq)

# Setup
Clone the repository and change to the created directory.
```bash
git clone https://github.com/mweigel/getting-started-spire-openbao.git && \
    cd getting-started-spire-openbao

export SRC_DIR=$(pwd)
export INSTALL_DIR=$(mktemp -d -t getting-started-spire-openbao-XXXXXX)
```

Create directories to hold configuration and data.
```bash
mkdir -p $INSTALL_DIR/config/{openbao,spire}
mkdir -p $INSTALL_DIR/data/openbao
mkdir -p $INSTALL_DIR/data/spire/{server,agent}
mkdir -p $INSTALL_DIR/logs
```

# Create CA and Certificates
From within the "certificates" directory, create the certificates used by OpenBao and the Spire OIDC provider.
```bash
# Initialise the certificate authority
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

# Create certificate for use with OpenBao
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server openbao-csr.json | cfssljson -bare $INSTALL_DIR/config/openbao/openbao

# Create certificate for use with Spire OIDC provider
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server spire-oidc-csr.json | cfssljson -bare $INSTALL_DIR/config/spire/spire-oidc
```

# Spire
From within the "spire" directory, create the Spire server, agent and OIDC provider configuration.
```bash
# Edit server.conf and configure the <trust_domain> and <spire_server_data> values
sed "s|<spire_server_data>|$INSTALL_DIR/data/spire/server|g; s|<trust_domain>|home.arpa|g" server.conf > $INSTALL_DIR/config/spire/server.conf

# Edit agent.conf and configure the <trust_domain> and <spire_agent_data> values
sed "s|<spire_agent_data>|$INSTALL_DIR/data/spire/agent|g; s|<trust_domain>|home.arpa|g" agent.conf > $INSTALL_DIR/config/spire/agent.conf

# Edit oidc-provider.conf and configure the <trust_domain> and <oidc_provider_config> value
sed "s|<oidc_provider_config>|$INSTALL_DIR/config/spire|g; s|<trust_domain>|home.arpa|g" oidc-provider.conf > $INSTALL_DIR/config/spire/oidc-provider.conf
```

Start Spire server.
```bash
spire-server run -config $INSTALL_DIR/config/spire/server.conf >> $INSTALL_DIR/logs/spire-server.log 2>&1 &
```

Create a join token and start the Spire agent with the join token to [register it with the server](https://spiffe.io/docs/latest/deploying/registering/).
```bash
export JOIN_TOKEN=$(spire-server token generate -output json | jq -r .value)

spire-agent run -config $INSTALL_DIR/config/spire/agent.conf -joinToken $JOIN_TOKEN >> $INSTALL_DIR/logs/spire-agent.log 2>&1 &
```

Create a [workload registration entry](https://spiffe.io/docs/latest/deploying/registering) and a simple selector for [Unix workload attestation](https://github.com/spiffe/spire/blob/v1.14.1/doc/plugin_agent_workloadattestor_unix.md). In this example, our own user ID is used as a selector. Any process running with this user ID will be able to obtain an SVID with the [SPIFFE ID](https://spiffe.io/docs/latest/spiffe-specs/spiffe-id/#2-spiffe-identity) shown below.
```bash
spire-server entry create -parentID spiffe://home.arpa/spire/agent/join_token/$JOIN_TOKEN -spiffeID spiffe://home.arpa/ob1 -selector unix:uid:$(id -u)
```

Start the Spire OIDC discovery provider. OpenBao will use the OIDC discovery provider to request key material used to verify SVIDs.
```bash
oidc-discovery-provider -config $INSTALL_DIR/config/spire/oidc-provider.conf >> $INSTALL_DIR/logs/oidc-provider.log 2>&1 &
```

At this point it should be possible to retrieve OIDC configuration and the JWKS from the Spire OIDC provider. This can be tested using Curl.
```bash
curl --cacert $SRC_DIR/certificates/ca.pem https://localhost:8443/.well-known/openid-configuration
curl --cacert $SRC_DIR/certificates/ca.pem https://localhost:8443/keys
```

# OpenBao
From within the "openbao" directory, create the OpenBao configuration.
```bash
sed "s|<openbao_config>|$INSTALL_DIR/config/openbao|g;  s|<openbao_data>|$INSTALL_DIR/data/openbao|g" config.hcl > $INSTALL_DIR/config/openbao/config.hcl
```

Start the OpenBao server.
```bash
bao server -config $INSTALL_DIR/config/openbao/config.hcl >> $INSTALL_DIR/logs/openbao.log 2>&1 &
```

Initialise and Unseal OpenBao. An unseal key and root token will be saved in bao-init.json and will have to be used to unseal and authenticate again if the OpenBao server is restarted.
```bash
export BAO_CACERT=$SRC_DIR/certificates/ca.pem

bao operator init -format=json --key-shares=1 --key-threshold=1 > bao-init.json

export BAO_TOKEN=$(cat bao-init.json | jq -r '.root_token')
export UNSEAL_KEY=$(cat bao-init.json | jq -r '.unseal_keys_hex[0]')

bao operator unseal $UNSEAL_KEY
```

Configure a JWT authentication method and role within OpenBao.
```bash
bao auth enable jwt

bao write auth/jwt/config \
    oidc_discovery_url=https://localhost:8443 \
    oidc_discovery_ca_pem=@$SRC_DIR/certificates/ca.pem

bao write auth/jwt/role/r1 \
    role_type="jwt" \
    bound_audiences="openbao" \
    user_claim="sub" \
    bound_subject="spiffe://home.arpa/ob1" \
    token_ttl="1h"
```

# Authenticate to OpenBao Using a SVID
Finally, we can now retrieve an SVID (a JWT in this case) from the Spire agent and use it to authenticate to OpenBao.
```bash
export JWT=$(spire-agent api fetch jwt -audience openbao -output=json | jq -r '.[0].svids.[0].svid')

bao write auth/jwt/login role=r1 jwt=$JWT
```

Upon successful authentication, an OpenBao token will be returned. The token has the "default" policy applied. From here you can experiment with different OpenBao features by updating the token policies applied to the "auth/jwt/role/r1" [authentication role](https://openbao.org/api-docs/auth/jwt/#createupdate-role).

# Stop running tasks
```bash
kill $(jobs -p)
```