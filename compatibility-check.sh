#!/usr/bin/env bash

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
PROJECT_DIR="${SCRIPT_DIR}"
UTILS_DIR="${PROJECT_DIR}/utils"
DISTRO=$("${UTILS_DIR}/distro-info")
DISTRO_UTILS_DIR="${UTILS_DIR}/${DISTRO}"
LOG_BASE_DIR="${SCRIPT_DIR}/logs"

# Enable these to mock the lshw output and iommu groups of other computers for testing purposes
#MOCK_SET=1
#LSHW_MOCK="${SCRIPT_DIR}/mock-data/$MOCK_SET-lshw"
#LSIOMMU_MOCK="${SCRIPT_DIR}/mock-data/$MOCK_SET-lsiommu"

if sudo which optirun &> /dev/null && sudo optirun echo>/dev/null ; then
    USE_BUMBLEBEE=true
    OPTIRUN_PREFIX="optirun "
else
    USE_BUMBLEBEE=false
    OPTIRUN_PREFIX=""
fi

if [ -z ${LSIOMMU_MOCK+x} ]; then
    IOMMU_GROUPS=$(sudo ${OPTIRUN_PREFIX}${UTILS_DIR}/lsiommu)
    MOCK_MODE=false
else
    IOMMU_GROUPS=$(cat "${LSIOMMU_MOCK}")
    MOCK_MODE=true
fi

if [ -z ${LSHW_MOCK+x} ]; then
    GPU_INFO=$(sudo lshw -class display -businfo)
else
    GPU_INFO=$(cat "${LSHW_MOCK}")
fi

LOG_OUTPUT=""
function log() {
    LOG_OUTPUT="${LOG_OUTPUT}$@\n"
}

NC='\033[0m' # No Color
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[1;33m'

function log_red() {
    echo -e "${RED}$@${NC}"
    log "$@"
}
function log_green() {
    echo -e "${GREEN}$@${NC}"
    log "$@"
}
function log_orange() {
    echo -e "${ORANGE}$@${NC}"
    log "$@"
}
function log_white() {
    echo -e "$@"
}

if [ "$MOCK_MODE" = true ]; then
    log_red "[Warning] Using mock data! The following output has nothing to do with this system!"
fi

# Check if UEFI is configured correctly
if systool -m kvm_intel -v &> /dev/null || systool -m kvm_amd -v &> /dev/null ; then
    UEFI_VIRTUALIZATION_ENABLED=true
    log_green "[OK] VT-X / AMD-V virtualization is enabled in the UEFI."
else
    UEFI_VIRTUALIZATION_ENABLED=false
    log_orange "[Warning] VT-X / AMD-V virtualization is not enabled in the UEFI! This is required to run virtual machines!"
fi

if [ "$IOMMU_GROUPS" != "" ] ; then
    UEFI_IOMMU_ENABLED=true
    log_green "[OK] VT-D / IOMMU is enabled in the UEFI."
else
    UEFI_IOMMU_ENABLED=false
    log_red "[Error] VT-D / IOMMU is not enabled in the UEFI! This is required to check which devices are in which IOMMU group and to use GPU passthrough!"
fi

# Check if kernel is configured correctly
if cat /proc/cmdline | grep --quiet iommu ; then
    KERNEL_IOMMU_ENABLED=true
    log_green "[OK] The IOMMU kernel parameters are set."
else
    KERNEL_IOMMU_ENABLED=false
    log_red "[Error] The iommu kernel parameters are missing! You have to add them in roder to use GPU passthrough!"
fi

GPU_IDS=($(echo "${GPU_INFO}" | grep "pci@" | cut -d " " -f 1 | cut -d ":" -f 2-))

GOOD_GPUS=()
BAD_GPUS=()
for GPU_ID in "${GPU_IDS[@]}"; do
    GPU_IOMMU_GROUP=$(echo "${IOMMU_GROUPS}" | grep "${GPU_ID}" | cut -d " " -f 3)

    if [ "$GPU_IOMMU_GROUP" == "" ] ; then
        log_red "[Error] Failed to find the IOMMU group of the GPU with the ID ${GPU_ID}! Have you enabled iommu in the UEFI and kernel?"
    else
        OTHER_DEVICES_IN_GPU_GROUP=$(echo "${IOMMU_GROUPS}" | grep "IOMMU Group ${GPU_IOMMU_GROUP} " | grep -v ${GPU_ID} | grep -v " Audio device " | grep -v " PCI bridge ")
        OTHER_DEVICES_IN_GPU_GROUP_NO_GPUS=$(echo "${OTHER_DEVICES_IN_GPU_GROUP}" | grep -v " VGA compatible controller " | grep -v " 3D controller ")

        if [ "$OTHER_DEVICES_IN_GPU_GROUP" == "" ] ; then
            log_green "[Success] GPU with ID '${GPU_ID}' could be passed through to a virtual machine!"
            GOOD_GPUS+=("$GPU_ID")
        elif [ "$OTHER_DEVICES_IN_GPU_GROUP_NO_GPUS" = "" ] ; then
            log_orange "[Warning] GPU with ID '${GPU_ID}' could be passed through to a virtual machine, but only together with the following devices: "
            log_orange "${OTHER_DEVICES_IN_GPU_GROUP}"
            GOOD_GPUS+=("${GPU_ID}")
        else
            log_orange "[Problem] Other devices have been found in the IOMMU group of the GPU with the ID '${GPU_ID}'. Depending on the devices, this could make GPU passthrough impossible to pass this GPU through to a virtual machine!"
            log_orange "The devices found in this GPU's IOMMU Group are:"
            log_red "${OTHER_DEVICES_IN_GPU_GROUP}"
            log_white "[Info] It might be possible to get it to work by putting the devices in different slots on the motherboard and or by using the ACS override patch. Otherwise you'll probably have to get a different motherboard. If you're on a laptop, there is nothing you can do as far as I'm aware. Although it would theoretically be possible for ACS support for laptops to exist. TODO: Find a way to check if the current machine has support for that."
            BAD_GPUS+=("${GPU_ID}")
        fi
    fi
done

GPU_LIST="Is Compatible?|Name|IOMMU_GROUP|PCI Address"

for GPU_ID in "${BAD_GPUS[@]}"; do
    PCI_ADDRESS="pci@0000:${GPU_ID}"
    NAME=$(echo "${GPU_INFO}" | grep "${GPU_ID}" | tr -s " " | cut -d " " -f 3-)
    IOMMU_GROUP=$(echo "${IOMMU_GROUPS}" | grep ${GPU_ID} | cut -d " " -f 3)
    GPU_LIST="${GPU_LIST}\nNo|${NAME}|${IOMMU_GROUP}|${PCI_ADDRESS}"
done

for GPU_ID in "${GOOD_GPUS[@]}"; do
    PCI_ADDRESS="pci@0000:${GPU_ID}"
    NAME=$(echo "${GPU_INFO}" | grep "${GPU_ID}" | tr -s " " | cut -d " " -f 3-)
    IOMMU_GROUP=$(echo "${IOMMU_GROUPS}" | grep "${GPU_ID}" | cut -d " " -f 3)
    GPU_LIST="${GPU_LIST}\nYes|${NAME}|${IOMMU_GROUP}|${PCI_ADDRESS}"
done

IOMMU_COMPATIBILITY_LVL=0 # 0: no GPUs to pass through; 1: at least 1 GPU for pt, but no GPU for host left; 2: at least one GPU for pt and at least one GPU for host left

if [ "${#GOOD_GPUS[@]}" == "0" ] ; then
    if [ "${#GPU_IDS[@]}" == "0" ] ; then
        log_red "[Warning] Failed to find any GPUs! Assuning this is correct, GPU passthrough is obviously impossible on this system in the current configuration!"
    else
        log_red "[Warning] This script was not able to identify a GPU in this that could be passed through to a VM!"
    fi
else
    log_green "[Success] There are ${#GOOD_GPUS[@]} GPU(s) in this system that could be passed through to a VM!"

    log_white ""
    GPU_LIST=$(echo -e "${GPU_LIST}" | column -t -s'|')
    while read -r line; do
        if echo "${line}" | grep --quiet Yes ; then
            log_green "${line}"
        elif echo "${line}" | grep --quiet No ; then
            log_red "${line}"
        else
            log_orange "${line}"
        fi
    done <<< "${GPU_LIST}"
    log_white ""

    if [ ${#GOOD_GPUS[@]} != 1 ] && grep -qE '^([0-9]+)( \1)*$' <<< $(echo $(echo "${IOMMU_GROUPS}" | grep -E $(echo "${GOOD_GPUS[@]}" | tr ' ' '|') | cut -d " " -f 3)) ; then
        if [ ${#BAD_GPUS[@]} == 0 ] ; then
            IOMMU_COMPATIBILITY_LVL=1
            log_orange "[Warning] All GPUs in this system are in the same IOMMU group. This would make GPU passthrough difficult (not impossible) because your host machine would be left without a GPU!"
        else
            IOMMU_COMPATIBILITY_LVL=2
            log_green "[Warning] Some of your GPUs are in the same IOMMU group. This means they could only be passed through together. You could still use a GPU that's in another group for your host system. (E.g. the one with the PCI address 'pci@0000:'${BAD_GPUS[0]} "
        fi
    else
        if [ "${#GPU_IDS[@]}" == "1" ] ; then
            IOMMU_COMPATIBILITY_LVL=1
            log_orange "[Warning] Only 1 GPU found! (Counting all GPUs, not just dedicated ones.) This would make GPU passthrough difficult (not impossible) because your host machine would be left without a GPU!"
        else
            IOMMU_COMPATIBILITY_LVL=2
            log_green "[OK] You have GPUs that are not in the same IOMMU group. At least one of these could be passed through to a VM and at least one of the remaining ones could be used for the host system."
        fi
    fi
fi


# If the device is a laptop
#if [ "$(sudo ${OPTIRUN_PREFIX}dmidecode --string chassis-type)" != "Desktop" ] ; then
    DEVICE_NAME=$(sudo ${OPTIRUN_PREFIX}dmidecode -s system-product-name)
    BIOS_VERSION=$(sudo ${OPTIRUN_PREFIX}dmidecode -s bios-version)
    LOG_DIR="${LOG_BASE_DIR}/$DEVICE_NAME/$BIOS_VERSION"
    DATE=`date +%Y-%m-%d`
    mkdir -p "${LOG_DIR}"

    log_white "[Info] Device name: $DEVICE_NAME"
    log_white "[Info] BIOS version: $BIOS_VERSION"

    if echo $IOMMU_GROUPS | grep --quiet " VGA compatible controller " ; then
        log_green "[OK] This system is probably MUXed. (The connection between the GPU(s) and the [internal display]/[display outputs] is multiplexed.)"
    else
        log_orange "[Warning] This system is probably MUX-less. (The connection between the GPU(s) and the [internal display]/[display outputs] is not multiplexed.)"
    fi



    echo ${DATE} > "${LOG_DIR}/date.log"
    echo "${IOMMU_GROUPS}" > "${LOG_DIR}/lsiommu.log"
    sudo ${OPTIRUN_PREFIX}dmidecode > "${LOG_DIR}/dmidecode.log"
    sudo ${OPTIRUN_PREFIX}dmesg > "${LOG_DIR}/dmesg.log"
    sudo ${OPTIRUN_PREFIX}lshw > "${LOG_DIR}/lshw.log"
    sudo ${OPTIRUN_PREFIX}lshw -short > "${LOG_DIR}/lshw-short.log"
    sudo ${OPTIRUN_PREFIX}lshw -class display -businfo > "${LOG_DIR}/lshw-gpu-businfo.log"
    sudo ${OPTIRUN_PREFIX}lspci > "${LOG_DIR}/lspci.log"
    sudo ${OPTIRUN_PREFIX}lsusb > "${LOG_DIR}/lsusb.log"
    sudo ${OPTIRUN_PREFIX}lsblk > "${LOG_DIR}/lsblk.log"
    sudo ${OPTIRUN_PREFIX}lscpu > "${LOG_DIR}/lscpu.log"
    sudo ${OPTIRUN_PREFIX}dmidecode -t bios > "${LOG_DIR}/bios.log"
    sudo ${OPTIRUN_PREFIX}cat /proc/cpuinfo > "${LOG_DIR}/cpuinfo.log"
    sudo ${OPTIRUN_PREFIX}cat /proc/meminfo > "${LOG_DIR}/meminfo.log"
    log_green "[OK] Logs have been created in ${LOG_DIR}"
    echo -e ${LOG_OUTPUT} > "${LOG_DIR}/general.log"
#fi

if [ "${UEFI_VIRTUALIZATION_ENABLED}" = true ] && [ "${UEFI_IOMMU_ENABLED}" = true ]  && [ "${KERNEL_IOMMU_ENABLED}" = true ] && [ "${IOMMU_COMPATIBILITY_LVL}" -gt "0" ] ; then
    log_green "If you found a notebook that appears to be GPU passthrough compatible, please open an issue on Github and let me know."
    if [ "${IOMMU_COMPATIBILITY_LVL}" -gt "1" ] ; then
        log_green "You may now proceed and run the generate-vm-config.sh script as mentioned in the README."
    fi
fi


#echo "Listing IOMMU Groups..."
#${SCRIPT_DIR}/utils/lsiommu

#echo "Listing GPU info with lshw..."
#sudo lshw -class display

#if [ -n ${MOCK_SET+x} ]; then
if [ "$MOCK_MODE" = true ]; then
    log_red "[Warning] Remember, the above output has been generated using the given mock data and has nothing to do with this system!"
fi
