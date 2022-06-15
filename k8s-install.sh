#!/bin/sh
# Script to create K8s cluster on Ubuntu Jammy VM's
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
source /etc/os-release
if [ "VERSION_CODENAME" != "jammy" ]; then
    echo "################################# "
    echo "############ WARNING ############ "
    echo "################################# "
    echo
    echo "This script was made for  Ubuntu 22.04!"
    echo "You're using: ${DISTRIB_DESCRIPTION}"
    echo "Better ABORT with Ctrl+C. Or press any key to continue the install"
    read
fi
echo "---------------------------------OS Tested ok-------------------------------------------------------------------------------------"


# SYSTEM prep
echo "---------------------------------Setting network----------------------------------------------------------------------------------"
# Set network
NICNAME=(ip link show | grep '<BROADCAST,MULTICAST,UP,LOWER_UP>' | awk '{print $2}')

rm /etc/netplan/*

cat > /etc/netplan/00-static.yaml <<EOF
network:
  ethernets:
    $NICNAME
      addresses:
      - $IPADDRESS
      gateway4: $GATEWAY
      nameservers:
        addresses:
        - $DNS
        search:
        - $SEARCHDOMAIN
  version: 2
EOF

chmod 644 /etc/netplan/00-static.yaml 

echo "---------------------------------Restarting network-------------------------------------------------------------------------------"
systemctl restart systemd-networkd
systemctl restart systemd-resolved

echo "---------------------------------Setting hostname---------------------------------------------------------------------------------"
hostnamectl set-hostname ${FQDN%%.*}

cat > /etc/hosts <<EOF
::1         ipv6-localhost ipv6-loopback
127.0.0.1   localhost.localdomain
127.0.0.1   localhost
EOF


echo "---------------------------------Configuring packages and environment-------------------------------------------------------------"
apt update 
apt upgrade
apt install -y sshpass docker.io apt-transport-https curl

systemctl start docker
systemctl enable docker



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

echo "---------------------------------remove sshpass-----------------------------------------------------------------------------------"
apt -y remove sshpass



echo "---------------------------------Disable swap-------------------------------------------------------------------------------------"
### disable linux swap and remove any existing swap partitions
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

echo "---------------------------------Add repositories---------------------------------------------------------------------------------"
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"



echo "---------------------------------Clear and recreate cache-------------------------------------------------------------------------"
apt update

echo "---------------------------------installing podman--------------------------------------------------------------------------------"
### install podman
# to be done


echo "---------------------------------installing  kubelet, kubeadm, kubectl, kubernetes-cni--------------------------------------------"
apt install kubeadm kubelet kubectl kubernetes-cni

echo "---------------------------------system config------------------------------------------------------------------------------------"
cat > /etc/modules-load.d/containerd.conf<<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf<<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system


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
kubeadm init --skip-token-print --pod-network-cidr=$CLUSTERIPRANGE --control-plane-endpoint=k8s-master.teekens.info

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
