#!/bin/bash

# Parse command line options using getopts
while getopts "fkc:i:p:s:u:t:a:n:l:" opt; do
  case $opt in
    f)
      INSTALL_FEDERATOR=true
      ;;
    k)
      INSTALL_KEYCLOAK=true
      ;;
    i)
      KEYCLOAK_IP="$OPTARG"
      ;;
    p)
      OPERATOR_ID="$OPTARG"
      ;;
    s)
      CLIENT_SECRET="$OPTARG"
      ;;
    t)
      KEYCLOAK_CLIENT_IDS=($OPTARG)
      ;;
    a)
      FEDERATOR_IPS=($OPTARG)
      ;;
    n)
      SSL_PASSWORDS=($OPTARG)
      ;;
    l)
      KAFKA_CONSUMER_PASSWORD="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

# Set default values
INSTALL_FEDERATOR=${INSTALL_FEDERATOR:-false}
INSTALL_KEYCLOAK=${INSTALL_KEYCLOAK:-false}

CURRENT_IP=$(ip -o route get to 1.1.1.1 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')

# If INSTALL_KEYCLOAK is true, set KEYCLOAK_IP to the current machine's IP
if [[ "$INSTALL_KEYCLOAK" = true ]]; then
    KEYCLOAK_IP=$CURRENT_IP
elif [[ "$INSTALL_FEDERATOR" = true ]]; then
    if [[ -z "$KEYCLOAK_IP" ]]; then
        echo "Error: KEYCLOAK_IP must be provided when INSTALL_KEYCLOAK is false."
        exit 1
    fi

    if [[ -z "$CLIENT_SECRET" ]]; then
        echo "Error: CLIENT_SECRET must be provided when INSTALL_KEYCLOAK is false."
        exit 1
    fi
fi

if [[ "$INSTALL_KEYCLOAK" = true || "$INSTALL_FEDERATOR" = true ]]; then
    if [[ -z "$OPERATOR_ID" ]]; then
        echo "Error: OPERATOR_ID must be provided when INSTALL_FEDERATOR or INSTALL_KEYCLOAK are true."
        exit 1
    fi

    if [[ -z "$KEYCLOAK_CLIENT_IDS" ]]; then
        KEYCLOAK_CLIENT_IDS=()
    fi

    KEYCLOAK_CLIENT_IDS=($OPERATOR_ID "${KEYCLOAK_CLIENT_IDS[@]:1}")
fi

if [[ "$INSTALL_FEDERATOR" = true ]]; then
    if [[ -z "$FEDERATOR_IPS" ]]; then
        FEDERATOR_IPS=()
    fi

    if [[ -z "$SSL_PASSWORDS" ]]; then
        SSL_PASSWORDS=()
    fi
    
    FEDERATOR_IPS=($CURRENT_IP "${FEDERATOR_IPS[@]:1}")
fi


KEYCLOAK_VERSION=7.1.7

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

SSL_PASSWORDS=("$KAFKA_CONSUMER_PASSWORD" "${SSL_PASSWORDS[@]:1}")

# Configure metricsForwarder.partnersConfig for each Keycloak client ID
METRICS_FORWARDER_CONFIG_ARGS=""
for i in "${!KEYCLOAK_CLIENT_IDS[@]}"; do
    if [[ -n "$METRICS_FORWARDER_CONFIG_ARGS" ]]; then
        METRICS_FORWARDER_CONFIG_ARGS="$METRICS_FORWARDER_CONFIG_ARGS "
    fi
    METRICS_FORWARDER_CONFIG_ARGS="$METRICS_FORWARDER_CONFIG_ARGS--set metricsForwarder.partnersConfig.${KEYCLOAK_CLIENT_IDS[i]}.bootstrap_servers=\"${FEDERATOR_IPS[i]}:31999\" \
        --set metricsForwarder.partnersConfig.${KEYCLOAK_CLIENT_IDS[i]}.security_protocol=\"SASL_PLAINTEXT\" \
        --set metricsForwarder.partnersConfig.${KEYCLOAK_CLIENT_IDS[i]}.sasl_mechanism=\"PLAIN\" \
        --set metricsForwarder.partnersConfig.${KEYCLOAK_CLIENT_IDS[i]}.sasl_plain_username=\"user1\" \
        --set metricsForwarder.partnersConfig.${KEYCLOAK_CLIENT_IDS[i]}.sasl_plain_password=\"${SSL_PASSWORDS[i]}\""
done

# Install and setup Keycloak
if [[ "$INSTALL_KEYCLOAK" = true ]]; then
    # Initialize array to store tokens
    declare -A CLIENT_TOKENS

    helm install keycloak oci://ghcr.io/codecentric/helm-charts/keycloakx \
        --version $KEYCLOAK_VERSION \
        --namespace keycloak \
        --create-namespace \
        --values values-keycloak.yaml \
        --wait
    
    # Login
    ACCESS_TOKEN=$(curl -X POST http://$KEYCLOAK_IP:30080/auth/realms/master/protocol/openid-connect/token \
                    -H "Content-Type: application/x-www-form-urlencoded" \
                    -d "client_id=admin-cli" \
                    -d "username=admin" \
                    -d "password=admin" \
                    -d "grant_type=password" \
                    | jq -r .access_token)
    
    curl -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        http://$KEYCLOAK_IP:30080/auth/admin/realms/master \
        -d '{
            "ssoSessionIdleTimeout": '$((3600*24*365))',
            "accessTokenLifespan": '$((3600*24*365))'
        }'

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

    printf '\n\n\n'

    # Print all client tokens
    for client_id in "${!CLIENT_TOKENS[@]}"; do
        echo "Client: $client_id, Token: ${CLIENT_TOKENS[$client_id]}" | tee -a tokens
    done

    printf '\n\n\n'

    CLIENT_SECRET=${CLIENT_TOKENS[$OPERATOR_ID]}
fi

# Install the new version of the OSM-MEC
cd osm-mec
helm -n osm-mec upgrade --install osm-mec deployment/helm-chart --create-namespace \
    --set domain=$OPERATOR_ID \
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
    --set kafka.KAFKA_CONSUMER_CONFIG.sasl_plain_password=$KAFKA_CONSUMER_PASSWORD \
    --set metricsForwarder.enabled=$INSTALL_FEDERATOR \
    $METRICS_FORWARDER_CONFIG_ARGS \
    --wait
cd ..

# Install the MEC Federator
if [[ "$INSTALL_FEDERATOR" = true ]]; then
    cd mec-federator/
    helm -n osm-mec upgrade --install mec-federator deployment/k8s/mec-federator --create-namespace \
        --set app.operatorId=$OPERATOR_ID \
        --set kafka.password=$KAFKA_PRODUCER_PASSWORD \
        --set oauth2.tokenEndpoint="http://$KEYCLOAK_IP:30080/auth/realms/master/protocol/openid-connect/token" \
        --wait
    cd ..
fi


# Because the OSM client is broken at first (this is a quick fix, not a good fix)
pip install pyangbind --break-system-packages
pip install packaging --break-system-packages
pip install verboselogs --break-system-packages
pip install prettytable --break-system-packages
pip install jsonpath-ng --break-system-packages
