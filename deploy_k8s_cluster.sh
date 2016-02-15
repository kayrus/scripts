#!/bin/bash -e

usage() {
  echo "Usage: $0 %cluster_size% [%pub_key_path%]"
}

print_green() {
  echo -e "\e[92m$1\e[0m"
}

export LIBVIRT_DEFAULT_URI=qemu:///system

USER_ID=${SUDO_UID:-$(id -u)}
USER=$(getent passwd "${USER_ID}" | cut -d: -f1)
HOME=$(getent passwd "${USER_ID}" | cut -d: -f6)

if [ "$1" == "" ]; then
  echo "Cluster size is empty"
  usage
  exit 1
fi

if ! [[ $1 =~ ^[0-9]+$ ]]; then
  echo "'$1' is not a number"
  usage
  exit 1
fi

if [[ "$1" -lt "2" ]]; then
  echo "'$1' is lower than 2 (minimal k8s cluster size)"
  usage
  exit 1
fi

if [[ -z $2 || ! -f $2 ]]; then
  echo "SSH public key path is not specified"
  if [ -n $HOME ]; then
    PUB_KEY_PATH="$HOME/.ssh/id_rsa.pub"
  else
    echo "Can not determine home directory for SSH pub key path"
    exit 1
  fi

  print_green "Will use default path to SSH public key: $PUB_KEY_PATH"
  if [ ! -f $PUB_KEY_PATH ]; then
    echo "Path $PUB_KEY_PATH doesn't exist"
    PRIV_KEY_PATH=$(echo ${PUB_KEY_PATH} | sed 's#.pub##')
    if [ -f $PRIV_KEY_PATH ]; then
      echo "Found private key, generating public key..."
      sudo -u $USER ssh-keygen -y -f $PRIV_KEY_PATH | sudo -u $USER tee ${PUB_KEY_PATH} > /dev/null
    else
      echo "Generating private and public keys..."
      sudo -u $USER ssh-keygen -t rsa -N "" -f $PRIV_KEY_PATH
    fi
  fi
else
  PUB_KEY_PATH=$2
  print_green "Will use this path to SSH public key: $PUB_KEY_PATH"
fi

OS_NAME="coreos"
PUB_KEY=$(cat ${PUB_KEY_PATH})
PRIV_KEY_PATH=$(echo ${PUB_KEY_PATH} | sed 's#.pub##')
CDIR=$(cd `dirname $0` && pwd)
IMG_PATH=${HOME}/.libvirt/${OS_NAME}
RANDOM_PASS=$(openssl rand -base64 12)
MASTER_USER_DATA_TEMPLATE=${CDIR}/k8s_master_user_data
NODE_USER_DATA_TEMPLATE=${CDIR}/k8s_node_user_data
ETCD_DISCOVERY=$(curl -s "https://discovery.etcd.io/new?size=$1")
CHANNEL=alpha
RELEASE=current
K8S_RELEASE=v1.1.7
FLANNEL_TYPE=vxlan
K8S_NET=10.100.0.0/16
K8S_DNS=10.100.0.254
K8S_DOMAIN=skydns.local
RAM=512
CPUs=1
IMG_NAME="coreos_${CHANNEL}_${RELEASE}_qemu_image.img"
IMG_URL="http://${CHANNEL}.release.core-os.net/amd64-usr/${RELEASE}/coreos_production_qemu_image.img.bz2"

IMG_EXTENSION=""
if [[ "${IMG_URL}" =~ \.([a-z0-9]+)$ ]]; then
  IMG_EXTENSION=${BASH_REMATCH[1]}
fi

case "${IMG_EXTENSION}" in
  bz2)
    DECOMPRESS="| bzcat";;
  xz)
    DECOMPRESS="| xzcat";;
  *)
    DECOMPRESS="";;
esac

if [ ! -d $IMG_PATH ]; then
  mkdir -p $IMG_PATH || (echo "Can not create $IMG_PATH directory" && exit 1)
fi

if [ ! -f $MASTER_USER_DATA_TEMPLATE ]; then
  echo "$MASTER_USER_DATA_TEMPLATE template doesn't exist"
  exit 1
fi

if [ ! -f $NODE_USER_DATA_TEMPLATE ]; then
  echo "$NODE_USER_DATA_TEMPLATE template doesn't exist"
  exit 1
fi

for SEQ in $(seq 1 $1); do
  if [ "$SEQ" == "1" ]; then
    VM_HOSTNAME="k8s-master"
    COREOS_MASTER_HOSTNAME=$VM_HOSTNAME
    USER_DATA_TEMPLATE=$MASTER_USER_DATA_TEMPLATE
  else
    NODE_SEQ=$[SEQ-1]
    VM_HOSTNAME="k8s-node-$NODE_SEQ"
    USER_DATA_TEMPLATE=$NODE_USER_DATA_TEMPLATE
  fi

  if [ ! -d $IMG_PATH/$VM_HOSTNAME/openstack/latest ]; then
    mkdir -p $IMG_PATH/$VM_HOSTNAME/openstack/latest || (echo "Can not create $IMG_PATH/$VM_HOSTNAME/openstack/latest directory" && exit 1)
  fi

  if [ -n $(selinuxenabled 2>/dev/null || echo "SELinux") ]; then
    if [[ -z $SUDO_YES ]]; then
      print_green "SELinux is enabled, this step requires sudo"
      read -p "Are you sure you want to modify SELinux fcontext? (Type 'y' when agree) " -n 1 -r
      echo
    fi

    if [[ $REPLY =~ ^[Yy]$ || "$SUDO_YES" == "yes" ]]; then
      unset $REPLY
      SUDO_YES="yes"
      # centos 7
      # /var/lib/libvirt/images(/.*)? all files system_u:object_r:virt_image_t:s0
      # fedora 23
      # /var/lib/libvirt/images(/.*)? all files system_u:object_r:virt_image_t:s0
      print_green "Adding SELinux fcontext for the '$IMG_PATH/$VM_HOSTNAME' path"
      sudo semanage fcontext -d -t virt_content_t "$IMG_PATH/$VM_HOSTNAME(/.*)?" || true
      sudo semanage fcontext -a -t virt_content_t "$IMG_PATH/$VM_HOSTNAME(/.*)?"
      sudo restorecon -R "$IMG_PATH"
    else
      SUDO_YES="no"
    fi
  else
    print_green "Skipping SELinux context modification"
  fi

  virsh pool-info $OS_NAME > /dev/null 2>&1 || virsh pool-create-as $OS_NAME dir --target $IMG_PATH || (echo "Can not create $OS_NAME pool at $IMG_PATH target" && exit 1)

  if [ ! -f $IMG_PATH/$IMG_NAME ]; then
    eval "wget $IMG_URL -O - $DECOMPRESS > $IMG_PATH/$IMG_NAME" || (rm -f $IMG_PATH/$IMG_NAME && echo "Failed to download image" && exit 1)
  fi

  if [ ! -f $IMG_PATH/${VM_HOSTNAME}.qcow2 ]; then
    virsh pool-refresh $OS_NAME
    virsh vol-create-as --pool $OS_NAME --name ${VM_HOSTNAME}.qcow2 --capacity 10G --format qcow2 --backing-vol $IMG_NAME --backing-vol-format qcow2 || (echo "Failed to create ${VM_HOSTNAME}.qcow2 volume image" && exit 1)
  fi

  sed "s#%PUB_KEY%#$PUB_KEY#g;\
       s#%HOSTNAME%#$VM_HOSTNAME#g;\
       s#%DISCOVERY%#$ETCD_DISCOVERY#g;\
       s#%RANDOM_PASS%#$RANDOM_PASS#g;\
       s#%MASTER_HOST%#$COREOS_MASTER_HOSTNAME#g;\
       s#%K8S_RELEASE%#$K8S_RELEASE#g;\
       s#%FLANNEL_TYPE%#$FLANNEL_TYPE#g;\
       s#%K8S_NET%#$K8S_NET#g;\
       s#%K8S_DNS%#$K8S_DNS#g;\
       s#%K8S_DOMAIN%#$K8S_DOMAIN#g" $USER_DATA_TEMPLATE > $IMG_PATH/$VM_HOSTNAME/openstack/latest/user_data

  virt-install \
    --connect qemu:///system \
    --import \
    --name $VM_HOSTNAME \
    --ram $RAM \
    --vcpus $CPUs \
    --os-type=linux \
    --os-variant=virtio26 \
    --disk path=$IMG_PATH/$VM_HOSTNAME.qcow2,format=qcow2,bus=virtio \
    --filesystem $IMG_PATH/$VM_HOSTNAME/,config-2,type=mount,mode=squash \
    --vnc \
    --noautoconsole \
#    --cpu=host
done

print_green "Use this command to connect to your cluster: 'ssh -i $PRIV_KEY_PATH core@$COREOS_MASTER_HOSTNAME'"
