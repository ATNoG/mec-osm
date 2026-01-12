#!/bin/bash


# OSM vars
OSM_LCM_IMAGE="ghcr.io/atnog/osm-mec-mano/lcm:latest"
OSM_NBI_IMAGE="ghcr.io/atnog/osm-mec-mano/nbi:latest"


# Install OSM
cd OSM
./devops/installers/install_osm.sh -D devops
cd ..

# Add OSM Hostname to bashrc
echo "export OSM_HOSTNAME=$(kubectl get --namespace osm -o jsonpath="{.spec.rules[0].host}" ingress nbi-ingress)" >> ~/.bashrc
export OSM_HOSTNAME=$(kubectl get --namespace osm -o jsonpath="{.spec.rules[0].host}" ingress nbi-ingress)

# Remove unused OSM components
flux uninstall --namespace=flux-system
helm uninstall gitea -n gitea
helm uninstall crossplane -n crossplane-system
kubectl delete namespaces minio-osm-tenant minio-operator gitea argo crossplane-system managed-resources
kubectl get ns | grep minio | awk '{print $1}' | xargs -r kubectl delete ns
kubectl get crds | grep minio | awk '{print $1}' | xargs -r kubectl delete crd


# Update OSM
kubectl patch deployment -n osm lcm --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}, {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "ghcr.io/atnog/osm-mec-mano/lcm:latest"}]'
kubectl patch deployment -n osm nbi --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}, {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "ghcr.io/atnog/osm-mec-mano/nbi:latest"}]'


# Install osm-mec
# Get the needed Information
OSM_NBI=$(kubectl -n osm get ingress nbi-ingress -o jsonpath='{.spec.rules[0].host}')
[ -z "$K8S_DEFAULT_IF" ] && K8S_DEFAULT_IF=$(ip route list|awk '$1=="default" {print $5; exit}')
[ -z "$K8S_DEFAULT_IF" ] && K8S_DEFAULT_IF=$(route -n |awk '$1~/^0.0.0.0/ {print $8; exit}')
[ -z "$K8S_DEFAULT_IF" ] && FATAL "Not possible to determine the interface with the default route 0.0.0.0"
K8S_DEFAULT_IP=`ip -o -4 a s ${K8S_DEFAULT_IF} |awk '{split($4,a,"/"); print a[1]; exit}'`
KAFKA_PORT=$(kubectl get svc -n osm kafka-controller-0-external -o jsonpath='{.spec.ports[0].nodePort}')
KAFKA_PRODUCER_PASSWORD=$(kubectl get secret -n osm kafka-user-passwords -o jsonpath="{.data.client-passwords}" | base64 --decode)
KAFKA_CONSUMER_PASSWORD=$(kubectl get secret -n osm kafka-user-passwords -o jsonpath="{.data.client-passwords}" | base64 --decode)

# Install the new version of the OSM-MEC
cd osm-mec
helm -n osm-mec upgrade --install osm-mec deployment/helm-chart --create-namespace \
    --set domain="IT_AVEIRO" \
    --set cfsPortal.deployment.image=ghcr.io/atnog/osm-mec/cfs-portal:main \
    --set cfsPortal.enabled=true \
    --set cfsPortal.deployment.env.FEDERATION=true \
    --set meao.deployment.image=ghcr.io/atnog/osm-mec/meao:main \
    --set meao.monitoring.deployment.image=ghcr.io/atnog/osm-mec/meao-monitoring:main \
    --set meao.migration.deployment.image=ghcr.io/atnog/osm-mec/meao-migration:main \
    --set oss.deployment.image=ghcr.io/atnog/osm-mec/oss:main \
    --set metricsForwarder.deployment.image=ghcr.io/atnog/osm-mec/metrics-forwarder:main \
    --set osm.host=$OSM_NBI \
    --set cfsPortal.ossHost=$K8S_DEFAULT_IP \
    --set kafka.KAFKA_PRODUCER_CONFIG.sasl_plain_password=$KAFKA_PRODUCER_PASSWORD \
    --set kafka.KAFKA_CONSUMER_CONFIG.sasl_plain_password=$KAFKA_CONSUMER_PASSWORD
cd ..
