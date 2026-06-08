#!/bin/bash

set -e

# Change Hostname
echo "CHANGING HOSTNAME..."

RANDOM_NUM=$(printf "%03d" $((RANDOM % 1000)))
NEW_HOSTNAME=worker-$RANDOM_NUM
OLD_HOSTNAME=$(hostname)

TEMP_HOSTS=$(mktemp)
sudo hostnamectl set-hostname "$NEW_HOSTNAME"
grep -v "$OLD_HOSTNAME" /etc/hosts > "$TEMP_HOSTS"
echo "127.0.1.1 $NEW_HOSTNAME" >> "$TEMP_HOSTS"
sudo mv "$TEMP_HOSTS" /etc/hosts
sudo chmod 644 /etc/hosts

# Enable Iptables Bridged Traffic
echo "ENABLING IPTABLES BRIDGED TRAFFIC..."

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Disable swap
echo "DISABLING SWAP..."

sudo swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

# Install containerd Runtime
echo "INSTALLING CONTAINERD RUNTIME..."

sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install containerd.io

sudo systemctl daemon-reload
sudo systemctl enable containerd --now
sudo systemctl start containerd.service


sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd

# Install critl
echo "INSTALLING CRITL..."

CRICTL_VERSION=v1.35.0
curl -LO https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz
sudo tar zxvf crictl-${CRICTL_VERSION}-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-${CRICTL_VERSION}-linux-amd64.tar.gz

cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# Install Kubernetes
echo "INSTALLING KUBERNETES TOOLS"

KUBERNETES_VERSION=v1.34

curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

KUBERNETES_INSTALL_VERSION="1.34.0-1.1"
sudo apt-get install -y kubelet="$KUBERNETES_INSTALL_VERSION" kubectl="$KUBERNETES_INSTALL_VERSION" kubeadm="$KUBERNETES_INSTALL_VERSION"
sudo apt-mark hold kubelet kubeadm kubectl

local_ip=$(hostname -I | awk '{print $1}')

cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF

# Join Node
echo "JOINING WORKER NODE..."

#TODO: Add Join Command for worker node

echo "ALL STEP SUCCESFULLY RUN, WORKER NODE ADDED TO CLUSTER"