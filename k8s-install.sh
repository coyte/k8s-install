#!/bin/sh
# Script to create K8s cluster on Photon OS VM's
# Needs master and worker VM 
# Run as root

# Usage: bash <(curl -s https://raw.githubusercontent.com/coyte/photon-k8s/main/photon-k8s-install.sh <master/worker>
# bash <(curl -s http://10.0.6.152/photon-k8s-install.sh


# Script needs env to be set
# $FQDN (resolvable via below DNS server)
# $ROOTPASSWORD
# $IPADDRESS (in CIDR notation 5.6.7.8/24)
# $GATEWAY
# $DNS
# $SEARCHDOMAIN
# $CLUSTERIPRANGE (=172.160.0.0/16)
# $AUTHORIZEDKEYSSERVER (user@server)
# $SSHPASS
# $KUBE_VERSION=1.23.6

# Source: http://kubernetes.io/docs/getting-started-guides/kubeadm

echo "---------------------------------Exit on error------------------------------------------------------------------------------------"
# set -e

echo "---------------------------------Test env variables-------------------------------------------------------------------------------"
if [[ -z $ROOTPASSWORD || -z $IPADDRESS || -z $GATEWAY || -z $DNS || -z $SEARCHDOMAIN || -z $CLUSTERIPRANGE || -z $AUTHORIZEDKEYSSERVER || -z $SSHPASS || -z $FQDN ]]; then
  echo 'One or more variables are undefined'
  exit 1
fi


echo "---------------------------------Test for correct OS & version--------------------------------------------------------------------"
source /etc/lsb-release
if [ "$DISTRIB_RELEASE" != "4.0" ]; then
    echo "################################# "
    echo "############ WARNING ############ "
    echo "################################# "
    echo
    echo "This script was made for  Photon OS 4.0!"
    echo "You're using: ${DISTRIB_DESCRIPTION}"
    echo "Better ABORT with Ctrl+C. Or press any key to continue the install"
    read
fi
echo "---------------------------------OS Tested ok-------------------------------------------------------------------------------------"


# SYSTEM prep
echo "---------------------------------Setting network----------------------------------------------------------------------------------"
# Set network
rm /etc/systemd/network/*
cat > /etc/systemd/network/10-static-en.network <<EOF
[Match]
Name=eth0

[Network]
Address=$IPADDRESS
Gateway=$GATEWAY
DNS=$DNS
Domains=$SEARCHDOMAIN
EOF

chmod 644 /etc/systemd/network/10-static-en.network 

echo "---------------------------------Restarting network-------------------------------------------------------------------------------"
systemctl restart systemd-networkd
systemctl restart systemd-resolved

echo "---------------------------------Setting hostname---------------------------------------------------------------------------------"
hostnamectl set-hostname ${FQDN%%.*}
cat > /etc/hosts <<EOF
::1         ipv6-localhost ipv6-loopback
127.0.0.1   localhost.localdomain
127.0.0.1   localhost
#127.0.0.1   ${FQDN%%.*} ${FQDN}
EOF


echo "---------------------------------Configuring packages and environment-------------------------------------------------------------"
tdnf update -yq
tdnf install -yq sshpass



cat > ~/.vimrc <<EOF
set tabstop=2
set shiftwidth=2
set expandtab
EOF

cat > ~/.bashrc <<EOF
alias ll='ls -al'
source <(kubectl completion bash)
alias k=kubectl
alias c=clear
complete -F __start_kubectl k
force_color_prompt=yes
EOF

echo "---------------------------------source .bashrc-----------------------------------------------------------------------------------"
source ~/.bashrc

echo "---------------------------------copy authorized keys-----------------------------------------------------------------------------"
# copy authrorized-keys
sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $AUTHORIZEDKEYSSERVER:~/.ssh/authorized_keys ~/.ssh/
chown root:root ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys
echo "Done copying authorized-keys"


echo "---------------------------------Disable swap-------------------------------------------------------------------------------------"
### disable linux swap and remove any existing swap partitions
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

#echo "---------------------------------Add repositories---------------------------------------------------------------------------------"
cat > /etc/yum.repos.d/kubernetes.repo<<EOF
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

echo "---------------------------------Clear and recreate cache-------------------------------------------------------------------------"
tdnf clean all -q
tdnf -yq makecache



echo "---------------------------------remove docker------------------------------------------------------------------------------------"
tdnf -yq remove docker 
echo "---------------------------------remove containerd--------------------------------------------------------------------------------"
tdnf -yq remove containerd
echo "---------------------------------remove sshpass-----------------------------------------------------------------------------------"
tdnf -yq remove sshpass


echo "---------------------------------installing podman--------------------------------------------------------------------------------"
### install podman
# to be done


echo "---------------------------------installing containerd, kubelet, kubeadm, kubectl, kubernetes-cni---------------------------------"
tdnf -yq install  containerd  kubeadm=${KUBE_VERSION}-00 kubectl=${KUBE_VERSION}-00 

echo "---------------------------------containerd config---------------------------------------------------------------------------------"

### containerd
cat > /etc/modules-load.d/containerd.conf<<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-kubernetes-cri.conf<<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system
mkdir -p /etc/containerd
cat > /etc/containerd/config.toml <<EOF
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "/var/lib/containerd"
state = "/run/containerd"
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      base_runtime_spec = ""
      container_annotations = []
      pod_annotations = []
      privileged_without_host_devices = false
      runtime_engine = ""
      runtime_root = ""
      runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        BinaryName = ""
        CriuImagePath = ""
        CriuPath = ""
        CriuWorkPath = ""
        IoGid = 0
        IoUid = 0
        NoNewKeyring = false
        NoPivotRoot = false
        Root = ""
        ShimCgroup = ""
        SystemdCgroup = true
EOF

echo "---------------------------------crictl config------------------------------------------------------------------------------------"
### crictl uses containerd as default
cat > /etc/crictl.yaml<<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF


echo "---------------------------------kubelet config-----------------------------------------------------------------------------------"
### kubelet should use containerd
cat > /etc/sysconfig/kubelet<<EOF
KUBELET_EXTRA_ARGS="--container-runtime remote --container-runtime-endpoint unix:///run/containerd/containerd.sock"
EOF


### start services
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
systemctl enable kubelet && systemctl start kubelet


### init k8s
rm /root/.kube/config || true
kubeadm init --kubernetes-version=${KUBE_VERSION} --ignore-preflight-errors=NumCPU --skip-token-print --pod-network-cidr=$CLUSTERIPRANGE --control-plane-endpoint=k8s-master.teekens.info

mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config

### CNI
#kubectl apply -f https://raw.githubusercontent.com/killer-sh/cks-course-environment/master/cluster-setup/calico.yaml


# etcdctl
ETCDCTL_VERSION=v3.5.1
ETCDCTL_VERSION_FULL=etcd-${ETCDCTL_VERSION}-linux-amd64
wget https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${ETCDCTL_VERSION_FULL}.tar.gz
tar xzf ${ETCDCTL_VERSION_FULL}.tar.gz
mv ${ETCDCTL_VERSION_FULL}/etcdctl /usr/bin/
rm -rf ${ETCDCTL_VERSION_FULL} ${ETCDCTL_VERSION_FULL}.tar.gz

echo
echo "### COMMAND TO ADD A WORKER NODE ###"
kubeadm token create --print-join-command --ttl 0
