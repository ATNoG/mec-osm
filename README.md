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
