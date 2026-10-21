# Laboratório gratuito NOC + AD — VMs + Docker

**Escopo:** apenas NOC e Active Directory, **sem SIEM / SOC / Wazuh**. Planejamento para ~38 GiB RAM livres no Xeon, sem tocar no sistema hospedeiro até confirmar qual hypervisor e discos existem.

## Dimensionamento (estimativa, não medição)

| VM | Responsabilidade | vCPU | RAM | Disco virtual |
|---|---|---:|---:|---:|
| dc01 — Debian | Samba AD DC, DNS, Kerberos | 2 | 2 GiB | 25 GiB |
| noc01 — Ubuntu Server | Docker: Zabbix, PostgreSQL, Uptime Kuma, Grafana opcional | 4 | 8 GiB | 100 GiB |
| win01 — Windows opcional | VM de testes para EPK, Zabbix agent 2 | 2 | 6 GiB | 70 GiB |
| linux01 — Debian | Endpoint de testes, Zabbix agent 2 | 1 | 2 GiB | 25 GiB |
| **Total** | **4 VMs** | **9** | **18 GiB** | **220 GiB** |

As linhas Docker **não** acrescentam memória à VM `noc01`; seus contêineres compartilham os 8 GiB dela. Isto preserva aproximadamente 20 GiB dos 38 livres informados, mas os números são só cotas iniciais de VM. Reavaliar conforme métricas, SSD disponível e memória efetivamente livre. Discos virtuais não equivalem ao uso imediato, e o banco Zabbix cresce com retenção.

Todas as ferramentas de servidor listadas são gratuitas sem licença de software. Windows não é gratuito permanentemente: use licença válida ou avaliação nos termos da Microsoft. Samba AD é uma alternativa livre ao controlador de domínio Windows Server, com diferenças de administração/compatibilidade a considerar.

## Arquitetura

Proxmox VE **somente se** o host puder ser dedicado à virtualização; sua instalação substitui o SO/disco escolhido. Se o Xeon já executa Windows ou Linux a ser mantido, use um hypervisor compatível já disponível. Não execute Docker dentro de uma VM Windows para estes serviços quando pode usar uma VM Ubuntu separada: menos sobrecarga e rede mais clara.

Exemplo de VLAN/rede virtual **isolada** `10.77.0.0/24`:

- `10.77.0.10` / `dc01.ad.home.arpa` — Samba AD/DNS.
- `10.77.0.30` / `noc01` — Docker e painéis Zabbix/Kuma.
- `10.77.0.100` / `win01` — cliente EPK (opcional).
- `10.77.0.110` / `linux01` — cliente Linux.
- Gateway virtual/outbound NAT **somente se necessário**, com firewall e sem DHCP indiscriminado na rede doméstica.

Os clientes ingressados no AD precisam resolver DNS pelo **dc01** (não use 8.8.8.8 como DNS secundário do cliente AD); Samba DNS pode encaminhar consultas externas a um resolvedor upstream. Valide NTP/time sync para Kerberos. O domínio `ad.home.arpa` é uma sugestão exclusiva do laboratório, não uma configuração obrigatória.

## O que roda onde?

**VM de domínio:** Debian + Samba AD DC diretamente no sistema, não em Docker. O controlador exige DNS/Kerberos/LDAP e gerenciamento de serviços/estado persistente; separá-lo em VM evita conflitos de DNS e rede com contêineres de monitoramento.

**VM NOC:** Ubuntu Server com Docker Engine e plugin Compose. O Compose em [docker/noc/compose.yaml](../docker/noc/compose.yaml) sobe:
- PostgreSQL 16 (persistência de métricas);
- Zabbix Server 7.0 LTS (NOC, triggers, discovery e coleta SNMP/agents);
- Zabbix Web (interface para dashboard);
- Uptime Kuma 2 (status/HTTP/TCP/PING e notificações);
- Grafana OSS 12.4.0 **opcional**, usando o perfil `dashboards` (visuais adicionais, plugin Zabbix configurado depois).

O Zabbix nativamente já oferece gráficos e dashboards: Grafana é opcional para poupar CPU/RAM.

## Implantar Docker na noc01

Antes dos comandos, instalar Docker Engine e o plugin `docker compose` no Ubuntu Linux seguindo as instruções oficiais: https://docs.docker.com/engine/install/ubuntu/.

A partir da raiz do EPK:

```bash
cd docker/noc
cp .env.example .env
nano .env
# Trocar NOC_POSTGRES_PASSWORD e GRAFANA_ADMIN_PASSWORD por senhas fortes.
docker compose --env-file .env config --quiet
docker compose up -d
docker compose ps
docker compose logs --tail 80 zabbix-server
```

Grafana (opcional):

```bash
docker compose --profile dashboards up -d
```

Para entrar nos painéis de sua máquina local **sem abrir portas no segmento LAN**, fazer um túnel SSH com a VM NOC:

```bash
ssh -L 8080:127.0.0.1:8080 -L 3001:127.0.0.1:3001 -L 3000:127.0.0.1:3000 usuario@IP_DA_VM_NOC
```

No navegador local: Zabbix `http://127.0.0.1:8080`, Kuma `http://127.0.0.1:3001` e, se habilitado, Grafana `http://127.0.0.1:3000`. Trocar senhas padrão/primeiro acesso imediatamente. Não publique estes serviços em IP público. Se precisar acessar diretamente de outro endpoint da VLAN privada, ajuste `NOC_WEB_BIND_IP` e restrinja acesso por firewall.

**Agentes Zabbix:** instalar Zabbix Agent 2 no sistema Windows e Linux **diretamente nas VMs** para métricas do SO. Começar por **checks passivos**, nos quais o servidor Zabbix inicia a conexão com o agente em TCP/10050. Para checks ativos (inclusive logs do EPK), configurar `ServerActive=10.77.0.30:10051` e definir `NOC_AGENT_BIND_IP=10.77.0.30` no Docker `.env`, liberando TCP/10051 apenas entre as VMs de laboratório. `Hostname` do agente deve coincidir com o host registrado no Zabbix.

## Testar Endpoint Provisioning Kit (EPK)

Executar os comandos abaixo em `win01` em **Windows PowerShell 5.1 elevado**, e somente em uma VM de laboratório:

```powershell
.\Tests\Invoke-EndpointProvisioningStaticTests.ps1
Copy-Item .\Config\Examples\active-directory.example.json .\Config\company.local.json
# Editar company.local.json para o domínio criado e manter Domain.Join.Enabled=false.
.\EndpointProvisioning.ps1 -Mode VALIDATE -Config .\Config\company.local.json -Silent
.\EndpointProvisioning.ps1 -Mode DRYRUN -Config .\Config\company.local.json -MachineType VM -Sector IT -Asset 0042 -Silent
.\EndpointProvisioning.ps1 -Mode AUDIT -Config .\Config\company.local.json -Silent
```

`VALIDATE` e `DRYRUN` não provisionam o endpoint, mas geram arquivos em `Runtime/`. Confirme relatório HTML/TXT e ZIP de evidência. Somente depois de configurar corretamente AD/DNS/OU e checar a VM/snapshot, considerar teste explícito de `COMPLETE -AllowDomainJoin`. Não automatize esse passo em CI. Não publique `Runtime/`, perfis locais ou credenciais.

## EPK ↔ Zabbix (NOC, sem SOC)

Monitorar o endpoint Windows com o template de agente Windows. Para acompanhar os erros de provisionamento, criar um item Zabbix tipo **Zabbix agent (active)** usando `logrt[]` (monitoramento de arquivos rotativos). Exemplo conceitual a ajustar ao diretório real do EPK:

```text
logrt["C:\Lab\Endpoint_Provisioning_Kit\Runtime\Logs\.*\.log","\\[ERR\\]",,,skip]
```

O Zabbix Agent deve ter permissão de leitura nos logs e `ServerActive` configurado; conferir a sintaxe no frontend para sua versão e testar com `VALIDATE` / `AUDIT`. Associar trigger e notificação a eventos de erro e também monitorar idade do último relatório gerado. Isso mostra o estado de provisionamento dentro do NOC sem criar um SIEM.

## Checklist de aceite (testes reais ainda pendentes no Xeon)

- [ ] Samba AD e DNS respondem `_ldap._tcp.ad.home.arpa` da VLAN de laboratório.
- [ ] Docker Compose passa em `docker compose config --quiet` na VM Linux.
- [ ] PostgreSQL, Zabbix Server, Zabbix Web e Uptime Kuma ficam saudáveis.
- [ ] Agentes Linux/Windows aparecem no Zabbix, com CPU/RAM/disco e disponibilidade.
- [ ] Uptime Kuma sinaliza indisponibilidade simulada e retorno (sem afetar rede principal).
- [ ] EPK `VALIDATE`, `DRYRUN`, `AUDIT` geram relatórios locais sem mudar o SO.
- [ ] Zabbix recebe um evento de log EPK de teste de forma controlada.
- [ ] Snapshots/backups das VMs e backup do volume PostgreSQL estão definidos.

Fontes: [Docker oficial do Zabbix](https://www.zabbix.com/documentation/7.0/en/manual/installation/containers), [Uptime Kuma Docker](https://github.com/louislam/uptime-kuma), [Grafana Docker OSS](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/), [Zabbix log monitoring](https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/zabbix_agent/log_items), [Samba AD](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller).
