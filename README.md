# atnog-mec

This repo contains all the necessary instructions and scripts to install and configure a Multi-access Edge Computing (MEC) environment using Open Source MANO (OSM) platform and ATNoG MEC components.

## Installation

Tested on Ubuntu 22.04 with 8 vCPUs, 16GB RAM and 120GB disk space.

### Initiate and update the submodule

Before running the main installation script, make sure to pull and update the submodule for mec-migration.

```bash
git submodule update --init --recursive
```

### Run the installation script

Execute the `run.sh` script to install and configure the MEC environment.

```bash
./run.sh
```

This script will install OSM, configure necessary components, and deploy the MEC services.

#### Command line options

The `run.sh` script accepts the following command line options:

- `-f`: Install the MEC Federator
- `-k`: Install Keycloak
- `-i <ip>`: Keycloak IP address (required when `-k` is not used)
- `-p <operator_id>`: Operator ID (required when `-k` is not used)
- `-s <client_secret>`: Client secret (required when `-k` is not used)
- `-t <client_ids>`: Comma-separated list of Keycloak client IDs (required when `-k` or `-f` is used). Multiple IDs should be separated by commas.
- `-a <ips>`: Comma-separated list of federator IPs (required when `-f` is used)
- `-n <passwords>`: Comma-separated list of SSL passwords (required when `-f` is used)
- `-l <password>`: Kafka consumer password (required when `-f` is used)

#### Examples

##### Install with Keycloak and Federator

To install the MEC environment with Keycloak and Federator:

```bash
./run.sh -f -k -p IT_AVEIRO -t "NOS" -a "10.255.41.185"
```

##### Install with existing Keycloak and Federator

To install the MEC environment with a Federator and an existing Keycloak:

```bash
./run.sh -f -i 10.255.41.197 -p NOS -s "client-secret" -t "IT_AVEIRO" -a "10.255.41.197" -n "8SalyT4ELW"
```

### Adding Additional Partners

To add additional partners to the configuration, you can use Helm upgrade with the `--set` flag to specify the partner configuration. For example, to add a new partner called "NEW_PARTNER":

```bash
helm -n osm-mec upgrade osm-mec osm-mec/deployment/helm-chart \
    --set metricsForwarder.partnersConfig.NEW_PARTNER.bootstrap_servers="10.255.41.198:31999" \
    --set metricsForwarder.partnersConfig.NEW_PARTNER.security_protocol="SASL_PLAINTEXT" \
    --set metricsForwarder.partnersConfig.NEW_PARTNER.sasl_mechanism="PLAIN" \
    --set metricsForwarder.partnersConfig.NEW_PARTNER.sasl_plain_username="user1" \
    --set metricsForwarder.partnersConfig.NEW_PARTNER.sasl_plain_password="new-password" \
    --reuse-values --wait
kubectl rollout restart deployment metrics-forwarder -n osm-mec
```

Each partner configuration should include:
- `bootstrap_servers`: The Kafka server address and port
- `security_protocol`: The security protocol to use (e.g., "SASL_PLAINTEXT")
- `sasl_mechanism`: The SASL mechanism (e.g., "PLAIN")
- `sasl_plain_username`: The username for authentication
- `sasl_plain_password`: The password for authentication


### Add the edges to your environment

To add an edge to your MEC environment, you need to add a k8s cluster in OSM. For that, first create the cluster using k3s or other distribution and then run the following command:

```bash
source ~/.bashrc

osm vim-create --name <vim-cluster-name> --user dummy --password dummy --auth_url http://dummy.dummy --project dummy --account_type dummy

osm k8scluster-add --creds <path-to-kubeconfig> --version '1.17' --vim <vim-cluster-name> --description "My cluster" --k8s-nets '{"net1": "osm-ext"}' <cluster-name>
```

### Add Monitoring (optional)

To add monitoring capabilities to your MEC environment, you can deploy cAdvisor as a CNF (Cloud-Native Function) in OSM. Follow these steps:

```bash
cd cadvisor-cnf
./run.sh
cd ..
```

This will deploy cAdvisor in your OSM environment, allowing you to monitor the performance and resource usage of your MEC applications.

## Usage

The web interface is available at `http://<HOST_IP>:30000`.
