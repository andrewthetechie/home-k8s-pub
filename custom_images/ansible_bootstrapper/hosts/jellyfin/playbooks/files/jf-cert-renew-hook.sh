#!/bin/sh

openssl pkcs12 -export -out /root/.acme.sh/jf.herrington.services_ecc/jf.herrington.services.pfx -inkey /root/.acme.sh/jf.herrington.services_ecc/jf.herrington.services.key -in /root/.acme.sh/jf.herrington.services_ecc/jf.herrington.services.cer -in /root/.acme.sh/jf.herrington.services_ecc/fullchain.cer -passout pass:
cp /root/.acme.sh/jf.herrington.services_ecc/jf.herrington.services.pfx /etc/ssl/jellyfin/jf.herrington.services.pfx
chown jellyfin:jellyfin /etc/ssl/jellyfin/jf.herrington.services.pfx
service jellyfin restart