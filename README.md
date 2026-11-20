# blog-haproxy-dns-lb

Companion code for the blog post
[HAProxy DNS Load Balancing: High Availability for DNS Infrastructure](https://blog.bsdserver.nl/haproxy-dns-load-balancing-high-availability-for-dns-infrastructure/).

It builds the post's **Complete Production Configuration** on two load balancer nodes.

The HAProxy community edition has no UDP mode, so the work is split. Clients only see the
virtual IPs on port 53.

| Traffic | Handled by | Details |
|---------|------------|---------|
| TCP 53 on `10.0.0.53` (internal) | HAProxy | resolvers with `leastconn`, public DNS as `backup`, 30 connections per source per 10 s |
| TCP 53 on `203.0.113.53` (authoritative) | HAProxy | authoritative servers, 20 connections per source per 10 s, 30 s server timeout for zone transfers |
| TCP 853 (DoT) | HAProxy | TLS termination, then the internal resolvers |
| UDP 53 on both VIPs | dnsdist | an nftables `prerouting` rule redirects it to dnsdist on 5353 (internal) and 5354 (authoritative) |
| `:8404` | HAProxy | stats (basic auth) and Prometheus `/metrics` |

**dnsdist** (2.1 from the official PowerDNS repository):
- **Internal listener (5353):**
  - only clients in `dns_lb_internal_clients` (RFC1918 by default); others get REFUSED, because
    the global ACL is open for the authoritative side;
  - the resolvers;
  - a `fallback` pool with 1.1.1.1 and 9.9.9.9 when no resolver is up;
  - 100 queries per second per source.
- **Authoritative listener (5354):** the authoritative servers only, 50 queries per second per
  source.
- **Console** on `127.0.0.1:5199` for `dnsdist -c`.

**keepalived:**
- moves the VIPs between the nodes;
- a node gives them up when `haproxy` or `dnsdist` stops (`killall -0 haproxy dnsdist`);
- `net.ipv4.ip_nonlocal_bind = 1` lets HAProxy on the backup node bind the VIPs it does not hold.

HAProxy comes from the official repositories:
- Ubuntu 24.04: `ppa:vbernat/haproxy-3.3`. 3.3 is the newest branch built for 24.04. It is
  short-lived and not LTS.
- Debian 13: haproxy.debian.net, 3.4 LTS.

## Differences from the post

- The post's keepalived example only lists `10.0.0.53`. This repo also puts `203.0.113.53` (the
  authoritative VIP) in `virtual_ipaddress`, so that address fails over too.
  - Set `dns_lb_vips` to change this, for example to put the public VIP on a second NIC.
- Secrets come from Ansible Vault instead of the post's placeholders:
  - the stats password (`changeme` in the post);
  - the VRRP password (`secret123` in the post);
  - the dnsdist console key.
- `dns_lb_keepalived_interface` defaults to the interface of the default route. The post
  uses `eth0`; Proxmox VMs usually have `ens18`.

## Requirements

- Terraform >= 1.6 and a Proxmox VE API token, if you want Terraform to create the VMs.
- ansible-core >= 2.15 on your workstation.
- DNS servers to balance. The defaults are the post's addresses:
  - resolvers `192.168.1.10-12`;
  - authoritative servers `192.168.1.20-22`.
- Both nodes in one L2 segment, with VRRP (IP protocol 112) allowed between them.

**`/etc/nftables.conf` starts with `flush ruleset`.** Enabling `nftables.service`, as the post
does, removes any other nftables or iptables-nft rules on the node: Docker, ufw, firewalld. Use
dedicated load balancer VMs.

## Quick start

```bash
# 1. VMs (optional: any two Ubuntu 24.04 or Debian 13 hosts work)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.yml

# 2. Secrets
cd ../ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml     # stats password, console key, VRRP password
ansible-vault encrypt group_vars/all/vault.yml

# 3. Load balancers
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass

# 4. The post's tests, from a client
dig @10.0.0.53 google.com A          # UDP, dnsdist
dig @10.0.0.53 +tcp google.com A     # TCP, HAProxy
dig @10.0.0.53 +tls google.com A     # DoT, HAProxy
ssh 10.0.0.2 sudo dnsdist -c -e 'showServers()'
```

`tests/verify.yml` runs these checks from Ansible. Add your client machines to a `dns_clients`
group and pass `verify_client_vips` (see the top of the file).

## Variables

All variables are in `ansible/roles/dns_lb/defaults/main.yml`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `haproxy_install_version` | `3.3` (Ubuntu), `3.4` (Debian) | HAProxy branch from the official repository |
| `dnsdist_install_branch` | `21` | dnsdist branch from repo.powerdns.com |
| `dns_lb_internal_vip` / `dns_lb_auth_vip` | `10.0.0.53` / `203.0.113.53` | listener addresses |
| `dns_lb_vips` | both VIPs as `/24` | keepalived `virtual_ipaddress` (`address`, optional `interface`) |
| `dns_lb_internal_resolvers` | resolver1-3 at 192.168.1.10-12 | `name`, `address` |
| `dns_lb_fallback_resolvers` | cloudflare 1.1.1.1, quad9 9.9.9.9 | HAProxy `backup` servers and the dnsdist `fallback` pool |
| `dns_lb_auth_servers` | auth1-3 at 192.168.1.20-22 | authoritative servers |
| `dns_lb_internal_clients` | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | sources the internal dnsdist listener answers (`NetmaskGroupRule`); others get REFUSED |
| `dns_lb_internal_udp_qps` / `dns_lb_auth_udp_qps` | `100` / `50` | dnsdist `MaxQPSIPRule` |
| `dns_lb_internal_tcp_conn_rate` / `dns_lb_auth_tcp_conn_rate` | `30` / `20` | HAProxy connections per source per 10 s |
| `dns_lb_dot_pem_src` | `""` (self-signed placeholder) | DoT certificate (cert+key PEM on the controller) |
| `dns_lb_keepalived_interface` | default route interface | VRRP interface |
| `vault_dns_lb_*` | see `vault.yml.example` | stats password, dnsdist console key, VRRP password |

The first host in the `dns_lb` group is the keepalived primary (MASTER, priority 101); the
other is the backup (priority 100).

## How it was tested

`tests/lab.sh` builds the post's networks on one Docker host:
- two Ubuntu 24.04 systemd containers as load balancers (HAProxy 3.3.17, dnsdist 2.1.3,
  keepalived 2.2.8);
- six BIND 9.20 containers as the resolvers and authoritative servers;
- two clients (10.0.0.100, 203.0.113.100).

Results, from fresh containers:
- `site.yml` run twice; the second run reports `changed=0`.
- `tests/verify.yml` passes:
  - configuration checks;
  - the nftables redirect;
  - `showServers()`;
  - exactly one holder per VIP;
  - UDP and TCP balancing over all three servers from both clients;
  - the internal listener (port 5353) answers the internal client and refuses the public one;
  - the post's dnsperf commands over UDP and TCP.
- `tests/lab.sh failover`:
  - stopping dnsdist or HAProxy on the primary moves the VIPs to the backup, and UDP and TCP
    keep answering;
  - a resolver that goes down is taken out of both dnsdist and HAProxy;
  - the per-source UDP limits drop the excess: about 115 qps answered of 400 (internal, limit
    100), about 60 of 200 (public, limit 50).
- CI (`.gitlab-ci.yml`) runs yamllint, ansible-lint (production profile), `terraform fmt`,
  `validate` and tflint.

## License

MIT
