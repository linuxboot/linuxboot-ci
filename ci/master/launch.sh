#!/bin/bash

# This script is executed on the compute node
#SBATCH -p compile # partition (queue) 
#SBATCH -N 1 # number of nodes 
#SBATCH -n 1 # number of cores 
#SBATCH --mem 100 # memory pool for all cores 
#SBATCH -t 0-2:00 # time (D-HH:MM) 
#SBATCH -o slurm.%N.%j.out # STDOUT 
#SBATCH -e slurm.%N.%j.err # STDERR

set -e
set -x

export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8

if [ -z "$SLURM_JOB_ID" ]
then
    {
        echo "WARNING : Job not launched by Slurm"
        echo "          If you are doing this for testing for testing purpose it can be fine"
        echo "          If not, there is maybe something wrong somewhere !"
    } >&2

    SLURM_JOB_ID=$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 32)
fi

git_url=$1

machine_name="ubuntu"

vmTemplate="/var/images/$machine_name.xml"
sourceImage="/var/images/$machine_name.img"

jobDir="$HOME/jobs/$SLURM_JOB_ID"
sourcesDir=${jobDir}/sources
artifactsDir=${jobDir}/artifacts
vmImage="${jobDir}/vm.img"
vmConfig="${jobDir}/vm.xml"
vmName="job-$SLURM_JOB_ID"
vmIP=

mkdir -p ${jobDir}
mkdir ${artifactsDir}

cp ${sourceImage} ${vmImage}

# Preparing the run
# scp -o StrictHostKeyChecking=no $USER@bastion:/var/images/$machine_name.img $HOME/images/$machine_name.$SLURM_JOB_ID.img

#
# Put SSH public key to be able to log into the VM and set the user as a sudoer
#
configureImage() {
    local mountDir=/tmp/mnt.$SLURM_JOB_ID
    mkdir -p ${mountDir}
    sudo guestmount -a ${vmImage} -m /dev/sda1 ${mountDir}
    sudo mkdir -p ${mountDir}/home/sds/.ssh
    sudo bash -c "echo 'sds     ALL=(ALL) NOPASSWD: ALL' >> ${mountDir}/etc/sudoers"
    sudo bash -c "cat $HOME/.ssh/id_rsa.pub >> ${mountDir}/home/sds/.ssh/authorized_keys"
    sudo chown -Rf 1000:1000 ${mountDir}/home/sds/.ssh
    sudo guestunmount ${mountDir}
    sudo rm -rf ${mountDir}
}

#
# Generate XML configuration for virsh from a template
#
generateVMConfiguration() {
    cat /var/images/ubuntu.xml                       \
          | sed "s/%SLURM_VM_NAME%/${vmName}/"       \
          | sed "s/%SLURM_VM_UUID%/$(uuidgen)/"      \
          | sed "s/%SLURM_VM_IMAGE%/$(echo ${vmImage} | sed 's/\//\\\//g')/" > ${vmConfig}
}

#
# Find IP address for VM from its name
#
# $1 - Machine name
#
findVMIP() {
    local name="$1"
    arp -an | grep "`virsh dumpxml ${name} | grep "mac address" | sed "s/.*'\(.*\)'.*/\1/g"`" | awk '{ gsub(/[\(\)]/,"",$2); print $2 }'
}

#
# Run virtual machine from XML file descriptor
#
runVM() {
    virsh create ${vmConfig}
}

#
# Destroy virtual machine and delete VM image
#
destroyVM() {
    virsh destroy ${vmName}
    rm -f ${vmImage}
}

#
# Wait for machine to get an IP address. When the IP address is found, it is written
# in file ${jobDir}/vm_ip. If this file is empty when the function returns, it probably
# means there's an issue somewhere
#
waitForVMToGetIP() {
    local max_retry=60
    local vmIP=""

    while [ -z "${vmIP}" ] && [ "${max_retry}" -gt 0 ]
    do
        sleep 5
        vmIP=$(findVMIP ${vmName})
        max_retry=$((max_retry-1))
    done

    echo ${vmIP} > ${jobDir}/vm_ip
}

#
# Wait for the VM to be reachable on SSH port
#
waitForVMToBeReachable() {
    local is_ssh_running=
    local max_retry=60

    while [ -z "${is_ssh_running}" ]
    do
        sleep 5
        is_ssh_running=$(nmap -p22 $vmIP | grep -i open)
    done

    if [ -n "$is_ssh_running" ]
    then
        echo true > ${jobDir}/vm_ssh
    fi
}

configureImage
generateVMConfiguration
runVM
waitForVMToGetIP

vmIP=$(cat ${jobDir}/vm_ip)

if [ "$vmIP" == "" ]; then
    # We got an error the VM doesn't have networking
    echo "No IP detected"
    exit 1
fi

waitForVMToBeReachable

if [ "$(cat ${jobDir}/vm_ssh)" != "true" ]
then
    # ssh server is not running
    echo "SSH server not running in VM"
    exit 1
fi

##################################################################### >>>> REAL JOB

git clone --depth 1 ${git_url} ${sourcesDir}

if [ ! -f ${sourcesDir}/.ci.yml ] ; then
    echo 1 > status
    echo "No build descriptor .ci.yml can be found in the source code repository." > error_msg
    destroyVM
    exit 0
fi

### Extract bash script from YAML descriptor
cat ${sourcesDir}/.ci.yml | yq .script | jq -r .[] > ${sourcesDir}/.ci.sh

### Copy source git repository into sandbox
scp -r ${sourcesDir} sds@${vmIP}:

### Run build
ssh -t sds@${vmIP} << EOF
    set -x
    mkdir ci

    touch ci/status
    touch ci/error_msg
    touch ci/log

    cd sources

    bash .ci.sh > ../ci/script.out 2> ../ci/script.err
EOF

### Get job status and log files and stdout stderr outputs
scp sds@${vmIP}:ci/* ${jobDir}

yaml_artifacts=$(cat ${sourcesDir}/.ci.yml | yq .artifacts)
for artifact in $(echo ${yaml_artifacts} | jq -r .[])
do
    scp sds@${vmIP}:sources/${artifact} ${artifactsDir}/${artifact}
done

##################################################################################

destroyVM
