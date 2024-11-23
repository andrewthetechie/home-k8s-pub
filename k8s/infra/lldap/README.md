1. Get Nauvoo LLDAP Credentials from dashlane
2. export LLDAP_PASS="PASSWORD HERE"
3. export LLDAP_JWT="JWT TOKEN HERE"
4. kubectl -n lldap create secret generic lldap-credentials --from-literal=lldap-jwt-secret=$LLDAP_JWT --from-literal=lldap-ldap-user-pass=$LLDAP_PASS -o yaml --dry-run=client | kubeseal -o yaml > sealedsecret-credentials.yaml