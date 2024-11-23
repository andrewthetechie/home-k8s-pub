<https://jonathangazeley.com/2021/01/05/using-truenas-to-provide-persistent-storage-for-kubernetes/>
<https://github.com/democratic-csi/democratic-csi#talos>

kubectl create namespace democratic-csi
kubectl label --overwrite namespace democratic-csi pod-security.kubernetes.io/enforce=privileged

helm repo add democratic-csi <https://democratic-csi.github.io/charts/>
helm repo update
helm upgrade --install --create-namespace --values freenas-nfs-hdd.yaml --namespace democratic-csi zfs-nfs-hdd democratic-csi/democratic-csi
helm upgrade --install --create-namespace --values freenas-nfs-ssd.yaml --namespace democratic-csi zfs-nfs-ssd democratic-csi/democratic-csi
helm upgrade --install --create-namespace --values freenas-iscsi-hdd.yaml --namespace democratic-csi zfs-iscsi-hdd democratic-csi/democratic-csi
helm upgrade --install --create-namespace --values freenas-iscsi-ssd.yaml --namespace democratic-csi zfs-iscsi-ssd democratic-csi/democratic-csi

kubectl patch storageclass freenas-iscsi-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

