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
if [ "$VERSION_CODENAME" != "focal" ]; then
    echo "################################# "
    echo "############ WARNING ############ "
    echo "################################# "
    echo
    echo "This script was made for  Ubuntu 20.04!"
    echo "You're using: ${DISTRIB_DESCRIPTION}"
    echo "Better ABORT with Ctrl+C. Or press any key to continue the install"
    read
fi
echo "---------------------------------OS Tested ok-------------------------------------------------------------------------------------"


# SYSTEM prep
echo "---------------------------------Setting network----------------------------------------------------------------------------------"
# Set network
export NICNAME=`ip link show | grep '<BROADCAST,MULTICAST,UP,LOWER_UP>' | awk '{print $2}'`

rm /etc/netplan/*

cat > /etc/netplan/00-static.yaml <<EOF
network:
  ethernets:
    $NICNAME
      addresses:
      - $IPADDRESS
      routes:
      - to: default
        via: $GATEWAY
      nameservers:
        addresses:
        - $DNS
        search:
        - $SEARCHDOMAIN
  version: 2
EOF

chmod 644 /etc/netplan/00-static.yaml 

echo "---------------------------------Restarting network-------------------------------------------------------------------------------"
netplan apply
systemctl restart systemd-resolved

#read -p "Check network, enter to continue"


echo "---------------------------------Setting hostname---------------------------------------------------------------------------------"
hostnamectl set-hostname ${FQDN%%.*}

cat > /etc/hosts <<EOF
::1         ipv6-localhost ipv6-loopback
127.0.0.1   localhost.localdomain
127.0.0.1   localhost
EOF



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



echo "---------------------------------copy authorized keys-----------------------------------------------------------------------------"
# copy authrorized-keys
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass
sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $AUTHORIZEDKEYSSERVER:~/.ssh/authorized_keys ~/.ssh/
DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq sshpass
chown root:root ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys

echo "---------------------------------remove sshpass-----------------------------------------------------------------------------------"
DEBIAN_FRONTEND=noninteractive apt-get -y -qq remove sshpass



echo "---------------------------------Disable swap-------------------------------------------------------------------------------------"
### disable linux swap and remove any existing swap partitions
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

echo "---------------------------------Add repositories---------------------------------------------------------------------------------"
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add
apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main" 

echo "---------------------------------Configuring packages and environment-------------------------------------------------------------"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-utils
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-transport-https curl ca-certificates

echo "---------------------------------system/modules config------------------------------------------------------------------------------------"
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

sysctl --system --quiet 


echo "---------------------------------installing containerd-------------------------------------------------------------------------"
# Check for updates on https://github.com/containerd/containerd/releases
curl -sLO https://github.com/containerd/containerd/releases/download/v1.6.6/containerd-1.6.6-linux-amd64.tar.gz
tar Cxzvf /usr/local containerd-1.6.6-linux-amd64.tar.gz
curl -sL https://raw.githubusercontent.com/containerd/containerd/main/containerd.service --output /usr/lib/systemd/system/containerd.service
systemctl daemon-reload
systemctl enable --now containerd

echo "---------------------------------installing runc-------------------------------------------------------------------------"
curl -sL https://github.com/opencontainers/runc/releases/download/v1.1.3/runc.amd64 --output /usr/local/sbin/runc
chmod 755 /usr/local/sbin/runc
echo "---------------------------------installing cni plugins-------------------------------------------------------------------------"
curl -sLO https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

echo "---------------------------------containerd confile file-------------------------------------------------------------------------"
mkdir -p /etc/containerd
cat > /etc/containerd/config.toml<<EOF
version = 2

root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = 0
#imports = ["/etc/containerd/runtime_*.toml", "./debug.toml"]

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0

[debug]
  address = "/run/containerd/debug.sock"
  uid = 0
  gid = 0
  level = "info"

[metrics]
  address = ""
  grpc_histogram = false

[cgroup]
  path = ""

[plugins]
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "crun"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    # crun: https://github.com/containers/crun
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun.options]
        BinaryName = "/usr/local/bin/crun"
        SystemdCgroup = true
    # gVisor: https://gvisor.dev/
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
      runtime_type = "io.containerd.runsc.v1"
    # Kata Containers: https://katacontainers.io/
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
EOF


echo "---------------------------------installing nerdctl--------------------------------------------------------------------------------"
NERDCTL_VERSION=0.20.0 # see https://github.com/containerd/nerdctl/releases for the latest release
archType="amd64"
wget -q "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-full-${NERDCTL_VERSION}-linux-${archType}.tar.gz" -O /tmp/nerdctl.tar.gz
tar -C /usr/local/bin/ -xzf /tmp/nerdctl.tar.gz --strip-components 1 bin/nerdctl

tar -C ~ -xzf /tmp/nerdctl.tar.gz libexec
mv ~/libexec/cni /usr/lib/libexec/
rm -rf ~/libexec
echo 'export CNI_PATH=/usr/lib/libexec/cni' >> ~/.bashrc
source ~/.bashrc


echo "---------------------------------installing podman--------------------------------------------------------------------------------"
### install podman
# to be done



echo "---------------------------------Adding repo--------------------------------------------"
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
DEBIAN_FRONTEND=noninteractive apt-get update

echo "---------------------------------installing  kubelet, kubeadm, kubectl--------------------------------------------"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kubeadm kubelet kubectl
DEBIAN_FRONTEND=noninteractive apt-mark hold kubelet kubeadm kubectl

echo "---------------------------------source .bashrc-----------------------------------------------------------------------------------"
source ~/.bashrc



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


#read -p "ready for kubeadmin, enter to continue"


### init k8s
rm /root/.kube/config || true
kubeadm config images pull
#read -p "images pulled, now kubeadmin init, enter to continue"
kubeadm init --skip-token-print --pod-network-cidr=$CLUSTERIPRANGE --control-plane-endpoint=k8s-master.teekens.info

mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config



### CNI
#kubectl apply -f https://raw.githubusercontent.com/killer-sh/cks-course-environment/master/cluster-setup/calico.yaml


# etcdctl
#ETCDCTL_VERSION=v3.5.1
#ETCDCTL_VERSION_FULL=etcd-${ETCDCTL_VERSION}-linux-amd64
#wget https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${ETCDCTL_VERSION_FULL}.tar.gz
#tar xzf ${ETCDCTL_VERSION_FULL}.tar.gz
#mv ${ETCDCTL_VERSION_FULL}/etcdctl /usr/bin/
#rm -rf ${ETCDCTL_VERSION_FULL} ${ETCDCTL_VERSION_FULL}.tar.gz

#echo
#echo "### COMMAND TO ADD A WORKER NODE ###"
#kubeadm token create --print-join-command --ttl 0
