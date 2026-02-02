#!/bin/bash

INSTALL_FEDERATOR=${1:-false}
INSTALL_KEYCLOAK=${2:-false}

if [[ "$INSTALL_KEYCLOAK" = true ]]; then
    KEYCLOAK_IP=$(ip -o route get to 1.1.1.1 | sed -n 's/.*src \([0-9.]\)\+.*/\1/p')
else
    if [[ -z "$3" ]]; then
        echo "Error: KEYCLOAK_IP must be provided when INSTALL_KEYCLOAK is false."
        exit 1
    fi
    KEYCLOAK_IP=$3
fi

if [[ "$INSTALL_KEYCLOAK" = false ]]; then
    if [[ -z "$4" ]]; then
        echo "Error: OPERATOR_ID must be provided when INSTALL_KEYCLOAK is false."
        exit 1
    fi
    OPERATOR_ID=$4

    if [[ -z "$5" ]]; then
        echo "Error: CLIENT_SECRET must be provided when INSTALL_KEYCLOAK is false."
        exit 1
    fi
    CLIENT_SECRET=$5
fi

KEYCLOAK_VERSION=7.1.7

# OSM vars
OSM_LCM_IMAGE="ghcr.io/atnog/osm-mec-mano/lcm:latest"
OSM_NBI_IMAGE="ghcr.io/atnog/osm-mec-mano/nbi:latest"

# Define Keycloak client IDs (if INSTALL_KEYCLOAK is set to true,
# the first will be automatically used to setup this domain in the federator)
KEYCLOAK_CLIENT_IDS=("IT_AVEIRO" "NOS")

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

# Initialize array to store tokens
declare -A CLIENT_TOKENS

# Install and setup Keycloak
if [[ "$INSTALL_KEYCLOAK" = true ]]; then
    helm install keycloak oci://ghcr.io/codecentric/helm-charts/keycloakx --version $KEYCLOAK_VERSION --namespace keycloak --create-namespace --values values-keycloak.yaml

    for client_id in "${KEYCLOAK_CLIENT_IDS[@]}"; do
        # Login
        ACCESS_TOKEN=$(curl -X POST http://$KEYCLOAK_IP:30080/auth/realms/master/protocol/openid-connect/token \
                        -H "Content-Type: application/x-www-form-urlencoded" \
                        -d "client_id=admin-cli" \
                        -d "username=admin" \
                        -d "password=admin" \
                        -d "grant_type=password" \
                        | jq -r .access_token)

        # Create client
        curl -X POST   http://$KEYCLOAK_IP:30080/auth/admin/realms/master/clients \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"clientId": "'$client_id'",
                "protocol": "openid-connect",
                "publicClient": false,
                "standardFlowEnabled": true,
                "serviceAccountsEnabled": true,
                "clientAuthenticatorType": "client-secret"}'

        # Get client ID
        CLIENT_UUID=$(curl -s "http://$KEYCLOAK_IP:30080/auth/admin/realms/master/clients?clientId=$client_id" \
            -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.[0].id')

        # Get client token
        token=$(curl -X GET http://$KEYCLOAK_IP:30080/auth/admin/realms/master/clients/$CLIENT_UUID/client-secret \
                    -H "Authorization: Bearer $ACCESS_TOKEN"\
                    | jq -r .value)
        CLIENT_TOKENS[$client_id]=$token
    done

    # Print all client tokens
    for client_id in "${!CLIENT_TOKENS[@]}"; do
        echo "Client: $client_id, Token: ${CLIENT_TOKENS[$client_id]}" >> tokens
    done
fi

# Install the MEC Federator
if [[ "$INSTALL_FEDERATOR" = true ]]; then
    if [[ "$INSTALL_KEYCLOAK" = true ]]; then
        OPERATOR_ID=${KEYCLOAK_CLIENT_IDS[0]}
        CLIENT_SECRET=${CLIENT_TOKENS[$OPERATOR_ID]}
    fi

    cd mec-federator/
    helm -n osm-mec install mec-federator deployment/k8s/mec-federator --create-namespace \
        --set app.operatorId=$OPERATOR_ID \
        --set kafka.password=$KAFKA_PRODUCER_PASSWORD \
        --set kafka.port=$KAFKA_PORT \
        --set oauth2.clientId=$OPERATOR_ID \
        --set oauth2.clientSecret=$CLIENT_SECRET \
        --set oauth2.tokenEndpoint="http://$KEYCLOAK_IP:30080/auth/realms/master/protocol/openid-connect/token"
fi

# Install the new version of the OSM-MEC
cd osm-mec
helm -n osm-mec upgrade --install osm-mec deployment/helm-chart --create-namespace \
    --set domain="IT_AVEIRO" \
    --set cfsPortal.deployment.image=ghcr.io/atnog/osm-mec/cfs-portal:main \
    --set cfsPortal.enabled=true \
    --set cfsPortal.deployment.env.FEDERATION=$INSTALL_FEDERATOR \
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
