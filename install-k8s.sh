#!/bin/bash

# Possible enhancements on this script:
# 1. Add logic to add hostname and IP in /etc/hosts on worker and master.
# 2. Remove Firewall logic. - DONE
# 3. Modify kubelet config on the worker nodes after worker has been added to cluster.
# 4. Change logic to install docker first before k8s components. - DONE
# 5. Add labels to worker node after worker has been added to cluster.
# 6. Automate worker kube join process
# 7. Add k8s cleanup (eg: previously created directories removal) logic before initializing this script.

if [ "$#" -eq 0 ]
then
    echo "Pass the arg correctly"
    echo "        Usage :"
    echo "               Master node - ./install-k8s.sh master <pod-network-cidr> <control-plane-endpoint>"
    echo "               Example     - ./install-k8s.sh master 10.241.0.0/16 tukhari"
    echo "               Worker node - ./install-k8s.sh worker"
    echo "               uninstall   - ./install-k8s.sh uninstall"
    exit 1
fi

if [ $1 == "uninstall" ]; then
        kubeadm reset
        sudo yum remove -y kubeadm kubectl kubelet kubernetes-cni kube*
        sudo yum remove -y docker-ce-18.09.9 docker-ce-cli-19.03.3  containerd.io
        sudo rm -rf ~/.kube
        exit 0

fi

sudo swapoff -a

tar -xvf cluster.tar


#We use Docker as a container Runtime
cd pkgs


rpm -ivh --force --nodeps yum-utils-1.1.31-54.el7_8.noarch.rpm
rpm -ivh --force --nodeps device-mapper-persistent-data-0.8.5-3.el7.x86_64.rpm
rpm -ivh --force --nodeps docker-lvm-plugin-1.13.1-102.git7f2769b.el7.centos.x86_64.rpm


tar -xvf Docker-rpms.tar.gz
cd docker-test
rpm -ivh --force --nodeps  *.rpm
cd ..


# Create required directories
sudo mkdir -p /etc/docker
sudo mkdir -p /etc/systemd/system/docker.service.d

# Create daemon json config file
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF


# Start and enable Services
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl restart docker


#Install kubelet, kubeadm and kubectl

#sudo tee /etc/yum.repos.d/kubernetes.repo<<EOF
#[kubernetes]
#name=Kubernetes
#baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
#enabled=1
#gpgcheck=0
#repo_gpgcheck=0
#gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
#EOF

cwd=$(pwd)
sudo yum clean all && sudo yum -y makecache
cd $cwd

tar -xvf Kubelet.tar.gz
cd kubelet
rpm -ivh --force *.rpm
cd ..
tar -xvf Kubectl.tar.gz
cd kubectl
rpm -ivh --force *.rpm
cd ..
rpm -ivh cri-tools-1.19.0-1.module_el8+12969+ebff6d46.x86_64.rpm

tar -xvf Kubeadm.tar.gz
cd kubeadm
rpm -ivh --force *.rpm
cd ..


cd $HOME

echo "******************Kubeadm kubectl versions************************"

kubeadm  version
kubectl version --client

sudo systemctl enable --now kubelet
sudo systemctl start kubelet

sleep 5



#Configuring Sysctl
sudo tee /etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

if [ $1 == "worker" ]; then
    cd $cwd/docker-images/calico
    docker load -i node.v3.15.5.tar

    cd $cwd/docker-images/k8s.gcr.io
    docker load -i proxy.tar

fi


#These commands should be run on masternode only

if [ $1 == "master" ]; then
    cd $cwd/docker-images/calico

    docker load -i cni.v3.15.5.tar
    docker load -i kube-controllers.v3.15.5.tar
    docker load -i node.v3.15.5.tar
    docker load -i pod2daemon-flexvol.v3.15.5.tar

    cd ..
    docker load -i  debian.latest.tar

    cd $cwd/docker-images/k8s.gcr.io
    docker load -i api.tar
    docker load -i controller.tar
    docker load -i coredns.1.7.0.tar
    docker load -i pause.3.2.tar
    docker load -i etcd.3.4.13-0.tar
    docker load -i scheduler.tar
    docker load -i proxy.tar


    cd $HOME

    #sudo kubeadm config images pull
    #Initializing the control plane
    #sudo kubeadm init --pod-network-cidr=10.241.0.0/16 --upload-certs --control-plane-endpoint=k8s-cluster-vm1 --ignore-preflight-errors=NumCPU

    sudo kubeadm init --pod-network-cidr=$2 --upload-certs --control-plane-endpoint=$3 --token-ttl 0


    #Kubectl commands
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    #install calico plugin
    cd $cwd
    tar xzvf release-v3.22.0.tgz
    cd ./release-v3.22.0/images
    docker load -i calico-cni.tar
    docker load -i calico-node.tar
    docker load -i calico-kube-controllers.tar
    docker load -i calico-pod2daemon.tar

    cd ../manifests/
    kubectl apply -f calico.yaml


    #installing calicoctl
    chmod +x calicoctl
    cp calicoctl /usr/local/bin

    DATASTORE_TYPE=kubernetes KUBECONFIG=~/.kube/config calicoctl get nodes -o yaml


    #install multus
    #cd $HOME
    #mkdir tmp
    #cd tmp
    #git clone https://github.com/intel/multus-cni
    #cd multus-cni/images/
    #git checkout v3.3
    #kubectl create -f multus-daemonset.yml
    #cd $HOME
    #rm -rf tmp/
fi
