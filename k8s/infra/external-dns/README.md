Makes k8s services resolvable inside of the home network

Kustomize can't resolve the oci registry that bitnami provides. Dump the helm chart to yaml, then split into resources.


echo -n "PIHOLE_PASSWORD" | kubectl -n external-dns create secret generic pihole-password --from-file=EXTERNAL_DNS_PIHOLE_PASSWORD=/dev/stdin -o yaml --dry-run=client | kubeseal -o yaml > sealed-secret-pihole-creds.yaml