#!/bin/bash

# Install OSM-dev
cd OSM
./devops/installers/install_osm.sh -D devops

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

# Install Docker
USER=$(whoami)
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
# Install the latest docker version
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Start and enable the Docker service without sudo
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER
newgrp docker

# Docker local image registry
docker run -d -p 5000:5000 --restart unless-stopped --name registry registry:2.7

# Install OSM updated services
./scripts/set_git_state.sh git
./scripts/dev_lcm.sh build apply

# Leave the OSM Folder
cd ..

# Install osm-mec
cd osm-mec
./run.sh

# Leave the osm-mec Folder
cd ..
