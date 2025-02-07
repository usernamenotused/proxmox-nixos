#!/bin/bash

# This is a helper script to setup a new nixos system on proxmox.
# created by @usernamenotused

function create_vm(){
    declare -A vm
    while [ $# -gt 0 ]; do
        shift
        case $1 in
            -i|--id)
                vm[id]=$2
                shift 2
                ;;
            -n|--name)
                vm[name]=$2
                shift 2
                ;;
            --description)
                vm[description]=$2
                shift 2
                ;;
            --storage)
                vm[storage]=$2
                shift 2
                ;;
            --pool)
                vm[pool]=$2
                shift 2
                ;;
            -s|--disk-size)
                vm[disk_size]=$2
                shift 2
                ;;
            --cpu-type)
                vm[cpu_type]=$2
                shift 2
                ;;
            -c|--cores)
                vm[cores]=$2
                shift 2
                ;;
            -m|--memory)
                vm[memory]=$2
                shift 2
                ;;
            --nix-channel)
                vm[nix_channel]=$2
                shift 2
                ;;
            --default-config)
                vm[default_config]=$2
                shift
                ;;
            --vz-template)
                vm[vz_template]=$2
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
        esac
    done

    # Check if all required parameters are set
    if [ -z "${vm[id]}" ] || [ -z "${vm[name]}" ] || [ -z "${vm[storage]}" ] || [ -z "${vm[disk_size]}" ] || [ -z "${vm[cores]}" ] || [ -z "${vm[memory]}" ]; then
        echo "Missing required parameters"
        exit 1
    fi
    # Set default values for optional parameters
    vm[description]=${vm[description]:-"NixOS VM"}
    vm[pool]=${vm[pool]:-"pmpool1"}
    vm[nix_channel]=${vm[nix_channel]:-"nixos-24.05"}
    vm[default_config]=${vm[default_config]:-false}
    vm[cpu_type]=${vm[cpu_type]:-host}
    vm[vz_template]=${vm[vz_template]:-"/mnt/pve/cephfs/template/iso/"}

    #set some helper variables
    URL="https://channels.nixos.org/${vm[nix_channel]}/latest-nixos-minimal-x86_64-linux.iso"
    FILENAME="${URL##*/}"
    LOCAL_IMAGE="$vm[vz_template]$FILENAME"
    if [[ ! -f $LOCAL_IMAGE ]]; then 
        echo "downloading nixos iso..."
        curl -s -L $URL > $LOCAL_IMAGE
    fi
    #verify the hash
    echo "verifying the hash..."
    HASH_URL="${URL}.sha256"
    #stash the hash in a variable
    HASH=$(curl -s -L $HASH_URL | awk '{print $1}')
    HASH=$(sha256sum $LOCAL_IMAGE |awk '{print $1}')
    if [[ $HASH != $CHASH ]]; then
        echo "hash mismatch, exiting..."
        exit 1
    fi

    #remove old VM if it exists
    if [[ $(qm list | grep ${vm[id]}) ]]; then
        echo "removing old VM..."
        qm stop ${vm[id]} --skiplock && qm destroy ${vm[id]} --destroy-unreferenced-disks --purge
    fi

    #create new VM
    echo "creating new VM..."
    qm create ${vm[id]} --name ${vm[name]} --memory ${vm[memory]} --cores ${vm[cores]} --sockets 1 --cpu ${vm[cpu_type]}
    qm set ${vm[id]} --description "${vm[description]}"
    qm set ${vm[id]} --machine q35 --ostype l26 --onboot 1 --scsihw virtio-scsi-pci
    # add iso image to vm
    qm set ${vm[id]} --ide2 ${vm[storage]}:iso/$FILENAME,media=cdrom

    # add disk to vm
    qm set ${vm[id]} --scsi0 ${vm[pool]}:${vm[disk_size]},ssd=1

    # set boot order
    qm set ${vm[id]} --bios ovmf --boot order='scsi0;ide2' --efidisk0 ${vm[pool]}:0,efitype=4mv --bootdisk scsi0
    # set network
    qm set ${vm[id]} --net0 virtio,bridge=vmbr0
    # enable guest agent
    qm set ${vm[id]} --agent 1

    # set autostart and start vm
    qm set ${vm[id]} --onboot 1
    qm start ${vm[id]}
    echo "VM ${vm[id]} created and started successfully."

    # wait for vm to boot
    echo "waiting for vm to boot..."
    sleep 30

    #todo get this to work
    : '
    # get vm ip
    IP=$(qm guest cmd ${vm[id]} network-get-interfaces | jq -r '.result[0].ip4_addresses[0]' | cut -d/ -f1)
    echo "VM IP: $IP"
    # do ssh into vm and run commands to install nixos
    echo "installing nixos..."
    ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" root@$IP << EOF
       # set password for nixos
       echo -e "password\npassword" | (passwd nixos)
       # Get the installer helper script from github
         curl -s -L https://raw.githubusercontent.com/usernamenotused/proxmox-nixos/main/installer.sh > installer.sh
       # mark the script as executable
         chmod +x installer.sh
         # run the script
         ./installer.sh
         #generate the hardware-configuration.nix file for the new disk
         nixos-generate-config --root /mnt
        # get the new configuration.nix from github
            curl -s -L https://raw.githubusercontent.com/usernamenotused/proxmox-nixos/main/configuration.nix > /mnt/etc/nixos/configuration.nix
        # install nixos
            nixos-install
EOF
   echo "NixOS installed successfully."
   echo "removing boot iso..."
    qm set ${vm[id]} --ide2 ${vm[storage]}:0
    # ssh into the vm and run a few commands to finish the setup
    ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" root@$IP << EOF
        # set password for nixos
        echo -e "password\npassword" | (passwd nixos)
EOF
'
    echo "VM ${vm[id]} created and started successfully."   
}

# Setup Nix VMs
create_vm -i 1001 -n "infraclone" --description "NixOS VM" --storage cephfs  --pool pmpool1 --disk-size 100G --cpu-type host --socket 2 --cores 4 --memory 8192 --nix-channel nixos-24.05 --default-config false