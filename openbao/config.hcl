api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

ui = true

storage "raft" {
  path = "<openbao_data>"
}

listener "tcp" {
  address       = "127.0.0.1:8200"
  tls_cert_file = "<openbao_config>/openbao.pem"
  tls_key_file = "<openbao_config>/openbao-key.pem"
}

disable_mlock = true