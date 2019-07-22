#!/bin/bash

export LC_ALL=C
export LANG=C

set -x

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
OC=${OC:-oc}

function get_git_tag {
    GIT_TAG=$(git describe --exact-match HEAD) || GIT_TAG=

    # Based on code from git-version-gen
    # Don't declare a version "dirty" merely because a time stamp has changed
    git update-index --refresh > /dev/null 2>&1

    dirty=`sh -c 'git diff-index --name-only HEAD' 2>/dev/null` || dirty=
    case "$dirty" in
        '') ;;
        *) # Don't build an 'official' version if git tree is dirty
            GIT_TAG=
    esac
    # end of git-version-gen code
}

function create_crc_libvirt_sh {
    destDir=$1

    hostInfo=$(sudo virsh net-dumpxml ${VM_PREFIX} | grep ${VM_PREFIX}-master-0 | sed "s/^[ \t]*//")
    masterMac=$(sudo virsh dumpxml ${VM_PREFIX}-master-0 | grep "mac address" | sed "s/^[ \t]*//")

    sed "s|ReplaceMeWithCorrectVmName|${CRC_VM_NAME}|g" crc_libvirt.template > $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectBaseDomain|${BASE_DOMAIN}|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectHost|$hostInfo|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectMac|$masterMac|g" $destDir/crc_libvirt.sh

    chmod +x $destDir/crc_libvirt.sh
}

function create_qemu_image {
    destDir=$1

    sudo cp /var/lib/libvirt/images/${VM_PREFIX}-master-0 $destDir
    sudo cp /var/lib/libvirt/images/${VM_PREFIX}-base $destDir

    sudo chown $USER:$USER -R $destDir
    ${QEMU_IMG} rebase -b ${VM_PREFIX}-base $destDir/${VM_PREFIX}-master-0
    ${QEMU_IMG} commit $destDir/${VM_PREFIX}-master-0

    # Resize the image from the default 1+15GB to 1+30GB
    # This should also take care of making the image sparse
    ${QEMU_IMG} create -o lazy_refcounts=on -f qcow2 $destDir/${CRC_VM_NAME}.qcow2 31G
    ${VIRT_RESIZE} --expand /dev/sda3 $destDir/${VM_PREFIX}-base $destDir/${CRC_VM_NAME}.qcow2

    rm -fr $destDir/${VM_PREFIX}-master-0 $destDir/${VM_PREFIX}-base
}

function update_json_description {
    srcDir=$1
    destDir=$2

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_rsa_crc"' \
        | ${JQ} '.clusterInfo.kubeConfig = "kubeconfig"' \
        | ${JQ} '.clusterInfo.kubeadminPasswordFile = "kubeadmin-password"' \
        | ${JQ} '.nodes[0].kind[0] = "master"' \
        | ${JQ} '.nodes[0].kind[1] = "worker"' \
        | ${JQ} ".nodes[0].hostname = \"${VM_PREFIX}-master-0\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} '.storage.diskImages[0].format = "qcow2"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "libvirt"' \
        >$destDir/crc-bundle-info.json
}

function copy_additional_files {
    srcDir=$1
    destDir=$2

    create_crc_libvirt_sh $destDir

    # Copy the kubeconfig and kubeadm password file
    cp $1/auth/kube* $destDir/

    # Copy the master public key
    cp id_rsa_crc $destDir/
    chmod 400 $destDir/id_rsa_crc

    update_json_description $srcDir $destDir
}

function generate_vbox_directory {
    srcDir=$1
    destDir=$2

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/

    ${QEMU_IMG} convert -f qcow2 -O vmdk $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vmdk
    
    diskSize=$(du -b $destDir/${CRC_VM_NAME}.vmdk | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.vmdk | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.vmdk\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.vmdk\"" \
        | ${JQ} '.storage.diskImages[0].format = "vmdk"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "virtualbox"' \
        >$destDir/crc-bundle-info.json
}

function generate_hyperkit_directory {
    srcDir=$1
    destDir=$2
    tmpDir=$3

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/
    cp $srcDir/${CRC_VM_NAME}.qcow2 $destDir/
    cp $tmpDir/vmlinuz-${kernel_release} $destDir/
    cp $tmpDir/initramfs-${kernel_release}.img $destDir/

    # Update the bundle metadata info
    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].kernel = \"vmlinuz-${kernel_release}\"" \
        | ${JQ} ".nodes[0].initramfs = \"initramfs-${kernel_release}.img\"" \
        | ${JQ} ".nodes[0].kernelCmdLine = \"${kernel_cmd_line}\"" \
        | ${JQ} '.driverInfo.name = "hyperkit"' \
        >$destDir/crc-bundle-info.json
}

function generate_hyperv_directory {
    srcDir=$1
    destDir=$2

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/

    ${QEMU_IMG} convert -f qcow2 -O vhdx -o subformat=dynamic $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vhdx

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} '.storage.diskImages[0].format = "vhdx"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "hyperv"' \
        >$destDir/crc-bundle-info.json
}

# CRC_VM_NAME: short VM name to use in crc_libvirt.sh
# BASE_DOMAIN: domain used for the cluster
# VM_PREFIX: full VM name with the random string generated by openshift-installer
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
JQ=${JQ:-jq}
VIRT_RESIZE=${VIRT_RESIZE:-virt-resize}
QEMU_IMG=${QEMU_IMG:-qemu-img}

if [[ $# -ne 1 ]]; then
   echo "You need to provide the running cluster directory to copy kubeconfig"
   exit 1
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

if ! which ${VIRT_RESIZE}; then
    sudo yum -y install /usr/bin/virt-resize libguestfs-xfs
fi

# The CoreOS image uses an XFS filesystem
# Beware than if you are running on an el7 system, you won't be able
# to resize the crc VM XFS filesystem as it was created on el8
if ! rpm -q libguestfs-xfs; then
    sudo yum install libguestfs-xfs
fi

if ! which ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi

random_string=$(sudo virsh list --all | grep -oP "(?<=${CRC_VM_NAME}-).*(?=-master-0)")
if [ -z $random_string ]; then
    echo "Could not find virtual machine created by snc.sh"
    exit 1;
fi
VM_PREFIX=${CRC_VM_NAME}-${random_string}

# Replace pull secret with a null json string '{}'
${OC} --config $1/auth/kubeconfig replace -f pull-secret.yaml

# Remove the Cluster ID with a empty string.
${OC} --config $1/auth/kubeconfig patch clusterversion version -p '{"spec":{"clusterID":""}}' --type merge

# Disable kubelet service and pull dnsmasq image from quay.io/crcon/dnsmasq
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl disable kubelet
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo podman pull quay.io/crcont/dnsmasq:latest

# Stop the kubelet service so it will not reprovision the pods
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl stop kubelet

# Remove all the pods from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl stopp $(sudo crictl pods -q)'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl rmp $(sudo crictl pods -q)'

# Remove pull secret from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- rm -f /var/lib/kubelet/config.json

# Get the rhcos ostree Hash ID
ostree_hash=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline | grep -oP "(?<=rhcos-).*(?=/vmlinuz)"')

# Get the rhcos kernel release
kernel_release=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'uname -r')

# Get the kernel command line arguments
kernel_cmd_line=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline')

# SCP the vmlinuz/initramfs from VM to Host in provided folder.
${SCP} core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/boot/ostree/rhcos-${ostree_hash}/* $1

# Download the hyperV daemons dependency on host
mkdir $1/hyperv
sudo yum install -y --downloadonly --downloaddir $1/hyperv hyperv-daemons

# SCP the downloaded rpms to VM
${SCP} -r $1/hyperv core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/

# Install the hyperV rpms to VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rpm-ostree install /home/core/hyperv/*.rpm'

# Remove the packages from VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- rm -fr /home/core/hyperv

# Shutdown the instance
sudo virsh shutdown ${VM_PREFIX}-master-0
# Wait till instance shutdown gracefully
until sudo virsh domstate ${VM_PREFIX}-master-0 | grep shut; do
    echo " ${VM_PREFIX}-master-0 still running"
    sleep 10
done

# instead of .tar.xz we use .crcbundle
crcBundleSuffix=crcbundle

# libvirt image generation
get_git_tag

if [ -z ${GIT_TAG} ]; then
    destDirSuffix="$(date --iso-8601)"
else
    destDirSuffix="${GIT_TAG}"
fi
libvirtDestDir="crc_libvirt_${destDirSuffix}"
mkdir $libvirtDestDir

create_qemu_image $libvirtDestDir

copy_additional_files $1 $libvirtDestDir

tar cJSf $libvirtDestDir.$crcBundleSuffix $libvirtDestDir

# HyperKit image generation
# This must be done after the generation of libvirt image as it reuse some of
# the content of $libvirtDestDir
hyperkitDestDir="crc_hyperkit_${destDirSuffix}"
mkdir $hyperkitDestDir
generate_hyperkit_directory $libvirtDestDir $hyperkitDestDir $1

tar cJSf $hyperkitDestDir.$crcBundleSuffix $hyperkitDestDir

# VirtualBox image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
vboxDestDir="crc_virtualbox_${destDirSuffix}"
mkdir $vboxDestDir
generate_vbox_directory $libvirtDestDir $vboxDestDir

tar cJSf $vboxDestDir.$crcBundleSuffix $vboxDestDir


# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
hypervDestDir="crc_hyperv_${destDirSuffix}"
mkdir $hypervDestDir
generate_hyperv_directory $libvirtDestDir $hypervDestDir

tar cJSf $hypervDestDir.$crcBundleSuffix $hypervDestDir
