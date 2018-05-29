#!/bin/bash

# This script is executed on the compute node
#SBATCH -p compile # partition (queue) 
#SBATCH -N 1 # number of nodes 
#SBATCH -n 1 # number of cores 
#SBATCH --mem 100 # memory pool for all cores 
#SBATCH -t 0-4:00 # time (D-HH:MM)
#SBATCH -o /var/lib/ci/%N.job.%j.out # STDOUT
#SBATCH -e /var/lib/ci/%N.job.%j.err # STDERR

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
git_branch=$2

machine_name="ubuntu"

vmTemplate="/var/lib/kvm/templates/$machine_name.xml"
sourceImage="/var/lib/kvm/images/$machine_name.img"

jobDir="/var/lib/ci/$SLURM_JOB_ID"
sourcesDir=${jobDir}/sources
artifactsDir=${jobDir}/artifacts
vmImage="/var/lib/kvm/vms/${SLURM_JOB_ID}.img"
vmConfig="${jobDir}/vm.xml"
vmName="job-$SLURM_JOB_ID"
vmUser="sds"
vmIP=

mkdir -p ${jobDir}

#
# Function call by a trap when script exits
#
cleanupAndExit() {
    if [ $(virsh list | grep ${vmName} | wc -l) -eq 1 ] ; then
        log "Destroying virtual machine..."
        virsh destroy ${vmName} >&2
    fi

    log "Cleanup..."
    rm -f ${vmImage}

    if [ ! -e ${jobDir}/status ] ; then
        echo 1 > ${jobDir}/status
    fi

    local status=$(cat ${jobDir}/status)
    local message=$(cat ${jobDir}/error_msg)

    if [ "${status}" -ne 0 ] ; then
        log ""
        if [ -n "${message}" ] ; then
            log "${message}"
        fi
        log "Build failed with status code ${status}"
    else
        log "Success !"
    fi
}

trap cleanupAndExit EXIT

cp ${sourceImage} ${vmImage}

log() {
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') ${1}"
}

#
# Put SSH public key to be able to log into the VM and set the user as a sudoer
#
configureImage() {
    local mountDir=/tmp/mnt.$SLURM_JOB_ID
    mkdir -p ${mountDir}
    sudo guestmount -a ${vmImage} -m /dev/sda1 ${mountDir}
    sudo mkdir -p ${mountDir}/home/${vmUser}/.ssh

    local sudoersFile=$(mktemp)
    echo "${vmUser}     ALL=(ALL) NOPASSWD: ALL" >> ${sudoersFile}
    sudo mv ${sudoersFile} ${mountDir}/etc/sudoers.d/${vmUser}
    sudo chown -f root:root ${mountDir}/etc/sudoers.d/${vmUser}

    sudo bash -c "cat $HOME/.ssh/id_rsa.pub >> ${mountDir}/home/${vmUser}/.ssh/authorized_keys"
    sudo chown -Rf 1000:1000 ${mountDir}/home/${vmUser}/.ssh
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
    virsh create ${vmConfig} >&2
}

#
# Function call by a trap when script exits
#
cleanupAndExit() {
    if [ $(virsh list | grep ${vmName} | wc -l) -eq 1 ] ; then
        log "Destroying virtual machine..."
        virsh destroy ${vmName} >&2
    fi

    log "Cleanup..."
    rm -f ${vmImage}

    if [ ! -e ${jobDir}/status ] ; then
        echo 1 > ${jobDir}/status
    fi

    local status=$(cat ${jobDir}/status)
    local message=$(cat ${jobDir}/error_msg)

    if [ "${status}" -ne 0 ] ; then
        log ""
        if [ -n "${message}" ] ; then
            log "${message}"
        fi
        log "Build failed with status code ${status}"
    else
        log "Success !"
    fi
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

log "=== Initialize building sandbox =============================================="

log "Setting up virtual machine configuration..."

configureImage
generateVMConfiguration

log "Running virtual machine..."

runVM

log "Waiting for virtual machine network..."

waitForVMToGetIP

vmIP=$(cat ${jobDir}/vm_ip)

if [ "$vmIP" == "" ]; then
    # We got an error the VM doesn't have networking
    log "ERROR : No IP detected"
    exit 1
fi

log "Waiting for virtual machine accessible from SSH..."

waitForVMToBeReachable

if [ "$(cat ${jobDir}/vm_ssh)" != "true" ]
then
    # ssh server is not running
    log "ERROR - SSH server not running in VM"
    exit 1
fi

### Get sources from Git

log "Fetching source code from git repository '${git_url}'..."

if [ -n "${git_branch}" ]; then
    git_branch="-b ${git_branch}"
fi

git clone --depth 1 ${git_branch} ${git_url} ${sourcesDir}

### Check Repository have de CI file descriptor

log "Reading CI descriptor .ci.yml"

if [ ! -f ${sourcesDir}/.ci.yml ] ; then
    echo 1 > status
    echo "No build descriptor .ci.yml can be found in the source code repository." > error_msg
    destroyVM
    exit 0
fi

### Generate bash script from YAML descriptor
cat ${sourcesDir}/.ci.yml | yq .script | jq -r .[] > ${sourcesDir}/.ci.sh

### Copy source git repository into sandbox
rsync -ae ssh ${sourcesDir} ${vmUser}@${vmIP}:

### Install additionnal tools into sandbox

log "Install additionnal tools into sandbox"

ssh -t ${vmUser}@${vmIP} >&2 <<-'EOF'
    set -x
    sudo apt update
    sudo apt install -y moreutils
EOF

log "=== Running scripts =========================================================="

echo "<% USER LOG PLACEHOLDER %>"

ssh -t ${vmUser}@${vmIP} >&2 <<-'EOF'
    set -x
    mkdir ci
    touch ci/status
    touch ci/error_msg
    touch ci/log
EOF

#
# TODO Do something smarter to share files between host and VM
#
GetLogFileFromVM() {
    while true ; do
        scp ${vmUser}@${vmIP}:ci/log ${jobDir} < /dev/null > /dev/null
        sleep 10
    done
}
GetLogFileFromVM &


### Run build
ssh -t ${vmUser}@${vmIP} >&2 <<-'EOF'
    set -x
    cd sources

    bash .ci.sh > ../ci/log 2>&1

    status_code=$?
    echo ${status_code} > ~/ci/status

    exit 0
EOF

log "=== Finish job ==============================================================="

log "Reading build information from sandbox..."

### Get job status and log files and stdout stderr outputs
scp ${vmUser}@${vmIP}:ci/* ${jobDir}

status_code=$(cat ${jobDir}/status)
if [[ -n "${status_code}" && "${status_code}" -ne 0 ]] ; then
    log "ERROR : Job failed with status code ${status_code}" > ${jobDir}/error_msg
    exit ${status_code}
fi

### Extract build artifacts from the VM

log "Extract build artifacts from sandbox..."

mkdir ${artifactsDir}

yaml_artifacts=$(cat ${sourcesDir}/.ci.yml | yq .artifacts)
if [ "${yaml_artifacts}" != "null" ] ; then
  for artifact in $(echo ${yaml_artifacts} | jq -r .[]) ; do
    # Check artifact exists
    if [ "$(ssh ${vmUser}@${vmIP} ls sources/${artifact} | wc -l)" -eq 0 ] ; then
        echo "ERROR : Job failed because artifact \"${artifact}\" cannot be found" > ${jobDir}/error_msg
        echo 1 > ${jobDir}/status
        exit 1
    fi
    # Copy artifact from VM
    log "Getting build artifacts '${artifact}'..."
    scp ${vmUser}@${vmIP}:sources/${artifact} ${artifactsDir}/${artifact}
  done
fi
