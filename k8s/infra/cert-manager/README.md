1. get Nauvoo cloudflare token from Dashlane
2. echo -n "CLOUDFLARE_TOKEN_HERE" | kubectl -n cert-manager create secret generic cloudflare-api-key --from-file=api-key=/dev/stdin -o yaml --dry-run=client | kubeseal -o yaml  > sealed-secret-cf-api.yaml
3. get Nauvoo Zerossl Secret from Dashlane
4. echo -n "EAB HMAC HERE" | kubectl -n cert-manager create secret generic zero-ssl-eabsecret --from-file=secret=/dev/stdin -o yaml --dry-run=client | kubeseal -o yaml > sealed-secret-zerossl.yaml
5. Commit and push changes