# Applied on the KMS, not on the main store: the main store's seal may only encrypt and
# decrypt with the transit key "autounseal".
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
