# Whoever stores provider keys (an admin CLI or an API): writes and deletes, never reads a
# value back (metadata only, to verify a write).
path "agent-ai/data/*"     { capabilities = ["create", "update"] }
path "agent-ai/metadata/*" { capabilities = ["read", "delete", "list"] }
