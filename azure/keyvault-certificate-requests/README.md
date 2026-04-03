# KeyVault CSR Generation and Merge

Had the need to generate a bunch of TLS certs for some web services via an external CA, so built this pair of scripts to generate CSRs and then merge them in later, given a simple text file as input.

List domains, one-per-line in the text file, then feed it into `generate-csr-keyvault` along with the name of your KeyVault, and it'll spit out `.csr` files into your current directory. Once you have the certificates in hand, merge them back in via the `merge-certs-to-keyvault` script to finish the op.