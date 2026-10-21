# Free NOC + SOC home lab (38 GiB RAM available)

This lab is designed for learning, for exercising the **Endpoint Provisioning Kit (EPK)**, and for generating **benign** monitoring/security telemetry. Nothing here installs onto the owner's hypervisor remotely. Start isolated, never connect a new lab DHCP service to the household LAN, and never expose its dashboards or AD services directly to the internet.

## License boundary

The always-free baseline is open source: Proxmox VE (community repository), Debian, Samba AD DC, Zabbix, Wazuh, and a Linux endpoint. The EPK itself requires Windows PowerShell 5.1, so a Windows client is **optional** and needs a valid existing Windows license or a time-limited evaluation in compliance with Microsoft terms. Windows Server evaluation expires after 180 days; it is **not** a permanently licensed free AD server. Electricity, disks and network hardware are not free.

## Memory/storage plan

This example assumes 48 GiB installed, approximately 10 GiB already in use, and approximately **38 GiB actually free**. Check your *exact* Xeon model, virtualization extensions, disk space/SSD, and host operating system before deployment. vCPU totals can be overcommitted, but an older Xeon may bottleneck under concurrent indexing.

| Guest | Service | vCPU | RAM (GiB) | Disk (GiB) |
|---|---|---:|---:|---:|
| dc01 | Debian + Samba AD DNS | 2 | 2 | 25 |
| noc01 | Ubuntu LTS + Zabbix server/front end/database | 2 | 8 | 60 |
| soc01 | Ubuntu LTS + Wazuh all-in-one | 4 | 10 | 120 |
| linux01 | Debian/Ubuntu Linux endpoint, Zabbix/Wazuh agents | 1 | 2 | 25 |
| win01 (optional) | Windows licensed/evaluation test VM + EPK | 2 | 6 | 70 |
| router01 (optional) | OPNsense/other isolated virtual router | 2 | 2 | 20 |
| **All guests** | | **13** | **30** | **320** |

30 GiB allocated leaves approximately 8 GiB headroom from the reported free memory; with no Windows guest or router the footprint drops to 22 GiB. Virtual disk capacities are maximum allocations, not an estimate of immediate used space. Use SSD storage and begin with shorter Wazuh log retention (e.g. 7-14 days), growing it only after measuring disk pressure. Zabbix's official example for a small, 1000-metric install uses 8 GiB RAM; Wazuh's quickstart recommends at least 8 GiB for 1-25 agents.

**Hypervisor choice:** Use Proxmox on a **dedicated** box if it may replace the current OS (installing it is destructive). If 38 GiB are unused *inside an existing Windows installation* that must stay, use your available Hyper-V (eligible Windows editions) or other compatible desktop hypervisor rather than reinstalling Proxmox. Do not assume all 48 GiB can be given to guests. Assign the VM memory as above only if the host continues to have its necessary reserve.

## Isolated example topology

- Private internal network: `10.77.0.0/24`, no uncontrolled bridge onto the home LAN.
- Router (if needed): `10.77.0.1` with a restrictive outbound-only NAT policy.
- `dc01.ad.home.arpa`: `10.77.0.10` (Samba AD DS, DNS, Kerberos).
- `soc01`: `10.77.0.20` (Wazuh dashboard/manager/indexer).
- `noc01`: `10.77.0.30` (Zabbix).
- `win01`: `10.77.0.100` (optional client test).
- `linux01`: `10.77.0.110`.

For AD-joined machines, configure DNS to use **only the Samba AD DNS server** at `10.77.0.10`; set up appropriate upstream forwarding on the server. Do not set a public DNS resolver as a secondary resolver on joined clients. Use `ad.home.arpa` as a lab-only DNS namespace; avoid `.local` because of mDNS collisions. Provide a dependable time source for Kerberos.

## Implementation stages

1. **Hypervisor:** Confirm Intel VT-x/VT-d where relevant, SSD free space and host reserve. Create internal virtual switch / VLAN and snapshots. Do not configure AD or router DHCP on the production network.
2. **Active Directory:** Install Debian, configure static address/DNS/hostname, and provision a new Samba AD domain using the official Samba documentation. Create LAB-specific users/OUs/groups with least privilege. Validate `kinit`, `samba-tool domain info` and `_ldap._tcp.ad.home.arpa` SRV DNS resolution.
3. **NOC:** Install the supported Zabbix release and database on `noc01`. Add agents to `dc01`, `soc01` and `linux01`. Collect availability, ping, CPU, RAM, disk, service health and certificate validity. Create a dashboard and alerts for the LAB hosts.
4. **SOC:** Install the supported Wazuh single-node stack on `soc01`, onboard `linux01` and the optional `win01`. On Windows, collect Security logs and Sysmon if installed with a reviewed configuration. Protect the dashboard with credentials and internal-only access.
5. **EPK read-only test:** Copy a profile locally (`Config/company.local.json` is Git-ignored). Initially set `Domain.Enabled=true` but **leave `Domain.Join.Enabled=false`**, point at `ad.home.arpa`, and configure `Domain.OU` only if that OU exists. Start with the commands below on `win01` from elevated Windows PowerShell 5.1. Keep application/certificate installs off.
6. **AD integration test (explicit approval only):** Only after the DNS and AD checks succeed, set `Domain.Join.Enabled=true`, review the selected OU, and invoke `COMPLETE -AllowDomainJoin` with prompted limited join credentials. Do this on the disposable LAB Windows VM only. Reboot if the operator explicitly chooses to do so.
7. **Observe and document:** Confirm Zabbix detects a test service stopped/restarted (restore it afterwards), Wazuh observes a benign failed logon on a dedicated test account, and EPK emits a report/evidence ZIP. Take screenshots with no real credentials.

## EPK commands (on the disposable Windows guest)

```powershell
# Run in the project folder from Windows PowerShell 5.1.
.\Tests\Invoke-EndpointProvisioningStaticTests.ps1
.\Tests\Test-EpkWazuhIntegration.ps1
Copy-Item .\Config\Examples\active-directory.example.json .\Config\company.local.json
# Edit only company.local.json to set your private AD name, and leave Join.Enabled=false.
.\EndpointProvisioning.ps1 -Mode VALIDATE -Config .\Config\company.local.json -Silent
.\EndpointProvisioning.ps1 -Mode DRYRUN -Config .\Config\company.local.json -MachineType VM -Sector IT -Asset 0042 -Silent
.\EndpointProvisioning.ps1 -Mode AUDIT -Config .\Config\company.local.json -Silent
```

These are read-only **with respect to provisioning**. They create local Runtime logs/reports/evidence as designed. Do not publish those files. `COMPLETE` may change the system and is **not** part of automated tests.

## EPK logs in Wazuh

1. Set the Windows Wazuh agent's `ossec.conf` to collect `Integrations/Wazuh/windows-agent.localfile.xml` under its existing `<ossec_config>` element; adjust the absolute path to the EPK checkout. Restart the agent.
2. Place `Integrations/Wazuh/epk_decoders.xml` under `/var/ossec/etc/decoders/` and `epk_rules.xml` under `/var/ossec/etc/rules/` on the LAB Wazuh server. Avoid duplicate IDs if you already have custom rules.
3. Run `sudo /var/ossec/bin/wazuh-logtest` and enter the sample line below. **Verify** decoder `epk-log` and rule ID `100111` (an EPK error). Adjust the decoder/rules if the installed Wazuh version behaves differently; they are templates, not verified live rules yet.
4. Restart the Wazuh manager with `sudo systemctl restart wazuh-manager` only once the local logtest passes. Run the EPK read-only audit again and confirm an alert/event arrives.

Sample synthetic line (not a real incident):

```text
[2026-10-21 14:05:09] [ERR] [DOM-027] Domain join blocked by operator
```

## Acceptance checklist

- [ ] Samba AD DNS resolves `_ldap._tcp.ad.home.arpa` from the LAB client.
- [ ] `dc01`, `noc01` and `soc01` remain isolated from the primary LAN.
- [ ] All Zabbix agents report metrics and a non-destructive availability alert works.
- [ ] Wazuh agents connect securely, and benign authentication telemetry is visible.
- [ ] Wazuh `wazuh-logtest` matches EPK `ERR` with custom rule `100111`.
- [ ] EPK static checks, `VALIDATE` and `DRYRUN` pass without provisioning.
- [ ] EPK reports/evidence contain only test names and stay out of Git.
- [ ] VM snapshots/backups and sensible alert/event retention are configured.

References: [Proxmox requirements](https://pve.proxmox.com/wiki/System_Requirements), [Zabbix requirements](https://www.zabbix.com/documentation/7.4/en/manual/installation/requirements), [Wazuh quickstart](https://documentation.wazuh.com/current/quickstart.html), [Wazuh custom decoders](https://documentation.wazuh.com/current/user-manual/ruleset/decoders/custom.html), [Samba wiki](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller), [Microsoft evaluation terms](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025).
