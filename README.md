# proxmox_tools
Some helpflul scripts for Proxmox 


# proxmox-quorum-one.sh 
chmod +x proxmox-quorum-one.sh

## Preview changes
./proxmox-quorum-one.sh --dry-run

## Apply changes
sudo ./proxmox-quorum-one.sh --apply

## Restore from backup
ls /root/corosync.conf.*.bak
sudo ./proxmox-quorum-one.sh --restore /root/corosync.conf.20250912-123456.bak
