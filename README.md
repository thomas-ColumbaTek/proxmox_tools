
# proxmox_tools

A collection of helpful scripts for [Proxmox VE](https://www.proxmox.com/).

---

## 🛠️ Scripts

### `proxmox-quorum-one.sh`

Force a Proxmox cluster to always consider itself quorate — even with only **1 node**.

⚠️ **Warning:**  
This script disables quorum enforcement.  
- ✅ Safe for **single-node clusters** or **lab/testing environments**  
- ❌ Dangerous in **multi-node production**: may cause **split-brain** if nodes lose network connectivity

---

## 🚀 Usage

Make the script executable:
```bash
chmod +x proxmox-quorum-one.sh
```

### 🔍 Preview changes
```bash
./proxmox-quorum-one.sh --dry-run
```

### ✅ Apply changes
```bash
sudo ./proxmox-quorum-one.sh --apply
```

### ♻️ Restore from backup
```bash
ls /root/corosync.conf.*.bak
sudo ./proxmox-quorum-one.sh --restore /root/corosync.conf.20250912-123456.bak
```

---

## 📂 Backups
Every time you apply changes, the script automatically creates a backup of your existing `/etc/pve/corosync.conf` in:

```
/root/corosync.conf.<timestamp>.bak
```

---

## 📜 License
MIT – feel free to use, modify, and share.
```
