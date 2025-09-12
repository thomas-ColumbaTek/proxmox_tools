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
