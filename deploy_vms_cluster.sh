#!/bin/bash -e

print_green() {
  echo -e "\e[92m$1\e[0m"
}

usage() {
  echo "Usage: $0 %os_name% %cluster_size% [%pub_key_path%]"
  echo "  Supported OS:"
  print_green "    * centos"
  print_green "    * ubuntu"
  print_green "    * debian"
  print_green "    * fedora"
  print_green "    * windows"
}

if [ "$1" == "" ]; then
  usage
  exit 1
fi

OS_NAME="$1"

case "$1" in
  coreos)
    echo "Use ./deploy_coreos_cluster.sh script"
    exit 1
    ;;
  centos)
    BOOT_HOOK="bootcmd:
  - echo 'DHCP_HOSTNAME=\${HOSTNAME}' >> /etc/sysconfig/network
runcmd:
  - service network restart"
    RELEASE=7
    IMG_NAME="CentOS-${RELEASE}-x86_64-GenericCloud.img"
    IMG_URL="http://cloud.centos.org/centos/${RELEASE}/images/CentOS-${RELEASE}-x86_64-GenericCloud.qcow2.xz"
    ;;
  fedora)
    BOOT_HOOK="bootcmd:
  - echo 'DHCP_HOSTNAME=\${HOSTNAME}' >> /etc/sysconfig/network
runcmd:
  - service network restart"
    CHANNEL=23
    RELEASE=20151030
    IMG_NAME="Fedora-Cloud-Base-${CHANNEL}-${RELEASE}.x86_64.qcow2"
    IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${CHANNEL}/Cloud/x86_64/Images/Fedora-Cloud-Base-${CHANNEL}-${RELEASE}.x86_64.qcow2"
    ;;
  debian)
    BOOT_HOOK="runcmd:
  - service networking restart"
    CHANNEL=8.3.0
    RELEASE=current
    IMG_NAME="${OS_NAME}_${CHANNEL}_${RELEASE}_qemu_image.img"
    IMG_URL="http://cdimage.debian.org/cdimage/openstack/${RELEASE}/debian-${CHANNEL}-openstack-amd64.qcow2"
    ;;
  ubuntu)
    BOOT_HOOK="runcmd:
  - service networking restart"
    CHANNEL=xenial
    RELEASE=current
    IMG_NAME="ubuntu_${CHANNEL}_${RELEASE}_qemu_image.img"
    IMG_URL="https://cloud-images.ubuntu.com/daily/server/${CHANNEL}/${RELEASE}/${CHANNEL}-server-cloudimg-amd64-disk1.img"
    ;;
  windows)
    WINDOWS_VARIANT="IE6.XP.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE7.Vista.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE8.XP.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE8.Win7.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE9.Win7.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE10.Win7.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE10.Win8.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE11.Win8.1.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="IE11.Win7.For.Windows.VirtualBox.zip"
    WINDOWS_VARIANT="Microsoft%20Edge.Win10.For.Windows.VirtualBox.zip" # https://az792536.vo.msecnd.net/vms/VMBuild_20150801/VirtualBox/MSEdge/Windows/Microsoft%20Edge.Win10.For.Windows.VirtualBox.zip

    IMG_NAME="IE11-Win7-disk1.vmdk"
    IMG_URL="https://az412801.vo.msecnd.net/vhd/VMBuild_20141027/VirtualBox/IE11/Windows/IE11.Win7.For.Windows.VirtualBox.zip"
    DISK_BUS="ide"
    DISK_FORMAT="vmdk"
    NETWORK_DEVICE="rtl8139"
    SKIP_CLOUD_CONFIG=true
    ;;
  *)
    echo "'$1' OS is not supported"
    usage
    exit 1
    ;;
esac

export LIBVIRT_DEFAULT_URI=qemu:///system
virsh nodeinfo > /dev/null 2>&1 || (echo "Failed to connect to the libvirt socket"; exit 1)
virsh list --all --name | grep -q "^${OS_NAME}1$" && (echo "'${OS_NAME}1' VM already exists"; exit 1)

USER_ID=${SUDO_UID:-$(id -u)}
USER=$(getent passwd "${USER_ID}" | cut -d: -f1)
HOME=$(getent passwd "${USER_ID}" | cut -d: -f6)

if [ "$2" == "" ]; then
  echo "Cluster size is empty"
  usage
  exit 1
fi

if ! [[ $2 =~ ^[0-9]+$ ]]; then
  echo "'$2' is not a number"
  usage
  exit 1
fi

if [[ -z $3 || ! -f $3 ]]; then
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
  PUB_KEY_PATH=$3
  print_green "Will use this path to SSH public key: $PUB_KEY_PATH"
fi

PUB_KEY=$(cat ${PUB_KEY_PATH})
PRIV_KEY_PATH=$(echo ${PUB_KEY_PATH} | sed 's#.pub##')
CDIR=$(cd `dirname $0` && pwd)
IMG_PATH=${HOME}/libvirt_images/${OS_NAME}
DISK_BUS=${DISK_BUS:-virtio}
NETWORK_DEVICE=${NETWORK_DEVICE:-virtio}
DISK_FORMAT=${DISK_FORMAT:-qcow2}
RAM=512
CPUs=1

IMG_EXTENSION=""
if [[ "${IMG_URL}" =~ \.([a-z0-9]+)$ ]]; then
  IMG_EXTENSION=${BASH_REMATCH[1]}
fi

case "${IMG_EXTENSION}" in
  bz2)
    DECOMPRESS="| bzcat";;
  xz)
    DECOMPRESS="| xzcat";;
  zip)
    DECOMPRESS="| bsdtar -Oxf - 'IE11 - Win7.ova' | tar -Oxf - 'IE11 - Win7-disk1.vmdk'";;
  *)
    DECOMPRESS="";;
esac

if [ ! -d $IMG_PATH ]; then
  mkdir -p $IMG_PATH || (echo "Can not create $IMG_PATH directory" && exit 1)
fi

CC="#cloud-config
password: passw0rd
chpasswd: { expire: False }
ssh_pwauth: True
users:
  - default:
    ssh-authorized-keys:
      - '${PUB_KEY}'
${BOOT_HOOK}
"

for SEQ in $(seq 1 $2); do
  VM_HOSTNAME="${OS_NAME}${SEQ}"
  if [ -z $FIRST_HOST ]; then
    FIRST_HOST=$VM_HOSTNAME
  fi

  if [ ! -d $IMG_PATH/$VM_HOSTNAME ]; then
    mkdir -p $IMG_PATH/$VM_HOSTNAME || (echo "Can not create $IMG_PATH/$VM_HOSTNAME directory" && exit 1)
  fi

  virsh pool-info $OS_NAME > /dev/null 2>&1 || virsh pool-create-as $OS_NAME dir --target $IMG_PATH || (echo "Can not create $OS_NAME pool at $IMG_PATH target" && exit 1)
  # Make this pool persistent
  (virsh pool-dumpxml $OS_NAME | virsh pool-define /dev/stdin)
  virsh pool-start $OS_NAME > /dev/null 2>&1 || true

  if [ ! -f $IMG_PATH/$IMG_NAME ]; then
    eval "wget $IMG_URL -O - $DECOMPRESS > $IMG_PATH/$IMG_NAME" || (rm -f $IMG_PATH/$IMG_NAME && echo "Failed to download image" && exit 1)
  fi

  if [ ! -f $IMG_PATH/${VM_HOSTNAME}.${DISK_FORMAT} ]; then
    virsh pool-refresh $OS_NAME
    virsh vol-create-as --pool $OS_NAME --name ${VM_HOSTNAME}.${DISK_FORMAT} --capacity 10G --format ${DISK_FORMAT} --backing-vol $IMG_NAME --backing-vol-format $DISK_FORMAT || \
      qemu-img create -f $DISK_FORMAT -b $IMG_PATH/$IMG_NAME $IMG_PATH/${VM_HOSTNAME}.${DISK_FORMAT} || \
      (echo "Failed to create ${VM_HOSTNAME}.${DISK_FORMAT} volume image" && exit 1)
    virsh pool-refresh $OS_NAME
  fi

  echo "$CC" > $IMG_PATH/$VM_HOSTNAME/user-data
  echo -e "instance-id: iid-${VM_HOSTNAME}\nlocal-hostname: ${VM_HOSTNAME}\nhostname: ${VM_HOSTNAME}" > $IMG_PATH/$VM_HOSTNAME/meta-data

  CC_DISK=""
  if [ -z $SKIP_CLOUD_CONFIG ]; then
    mkisofs \
      -input-charset utf-8 \
      -output $IMG_PATH/$VM_HOSTNAME/cidata.iso \
      -volid cidata \
      -joliet \
      -rock \
      $IMG_PATH/$VM_HOSTNAME/user-data \
      $IMG_PATH/$VM_HOSTNAME/meta-data || (echo "Failed to create ISO image"; exit 1)
    virsh pool-refresh $OS_NAME
    CC_DISK="--disk path=$IMG_PATH/$VM_HOSTNAME/cidata.iso,device=cdrom"
  fi

  virt-install \
    --connect qemu:///system \
    --import \
    --name $VM_HOSTNAME \
    --ram $RAM \
    --vcpus $CPUs \
    --os-type=linux \
    --os-variant=virtio26 \
    --network network=default,model=${NETWORK_DEVICE} \
    --disk path=$IMG_PATH/$VM_HOSTNAME.${DISK_FORMAT},format=${DISK_FORMAT},bus=$DISK_BUS \
    $CC_DISK \
    --vnc \
    --noautoconsole \
#    --cpu=host
done

print_green "Use this command to connect to your cluster: 'ssh -i $PRIV_KEY_PATH ${OS_NAME}@$FIRST_HOST'"