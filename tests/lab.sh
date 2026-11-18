#!/bin/bash
# How the repo was tested, on one Docker host, with the post's addresses:
#   10.0.0.0/24      internal network: dnslb1 .2, dnslb2 .3, VIP .53, client .100
#   203.0.113.0/24   public network:   dnslb1 .2, dnslb2 .3, VIP .53, client .100
#   192.168.1.0/24   DNS servers (BIND 9.20): resolvers .10-.12, authoritative .20-.22
# The load balancers are Ubuntu 24.04 systemd containers; the clients run dig and dnsperf.
# Usage: tests/lab.sh up | run | failover | down      (LAB_PREFIX=lab by default)
set -u
P=${LAB_PREFIX:-lab}-dns; T=$(cd "$(dirname "$0")" && pwd); W=$T/../.lab
case "${1:-}" in
up)
  docker network create --subnet 10.0.0.0/24 $P-int >/dev/null
  docker network create --subnet 203.0.113.0/24 $P-pub >/dev/null
  docker network create --subnet 192.168.1.0/24 $P-srv >/dev/null
  mkdir -p "$W"
  for s in 10:resolver1:yes 11:resolver2:yes 12:resolver3:yes 20:auth1:no 21:auth2:no 22:auth3:no; do
    IFS=: read -r ip name rec <<<"$s"; mkdir -p "$W/$name"
    sed "s/RECURSION/$rec/" "$T/bind/named.conf" > "$W/$name/named.conf"
    sed "s/SERVERNAME/$name/" "$T/bind/lab.zone" > "$W/$name/lab.zone"; chmod -R a+rX "$W/$name"
    docker run -d --name $P-$name --network $P-srv --ip 192.168.1.$ip -v "$W/$name":/etc/bind:ro \
      internetsystemsconsortium/bind9:9.20 -g -4 -c /etc/bind/named.conf -u bind >/dev/null
  done
  for n in 1 2; do
    docker run -d --name $P-lb$n --hostname dnslb$n --network $P-int --ip 10.0.0.$((n+1)) --privileged --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock jrei/systemd-ubuntu:24.04 >/dev/null
    docker network connect --ip 203.0.113.$((n+1)) $P-pub $P-lb$n
    docker network connect --ip 192.168.1.$((n+1)) $P-srv $P-lb$n
  done
  for c in int:10.0.0.100 pub:203.0.113.100; do
    docker run -d --name $P-cli${c%%:*} --network $P-${c%%:*} --ip ${c#*:} ubuntu:24.04 sleep infinity >/dev/null
  done
  sleep 3
  for c in $P-lb1 $P-lb2 $P-cliint $P-clipub; do
    docker exec $c bash -c 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 sudo ca-certificates gnupg iproute2 curl dnsutils >/dev/null 2>&1' &
  done; wait
  for c in $P-cliint $P-clipub; do docker exec $c bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsperf >/dev/null 2>&1'; done
  # /etc/nftables.conf starts with "flush ruleset", which also removes Docker's
  # rules for its embedded DNS inside the container: use the lab resolver instead
  for n in 1 2; do docker exec $P-lb$n sh -c 'echo "nameserver 192.168.1.10" > /etc/resolv.conf'; done
  { printf 'all:\n  children:\n    dns_lb:\n      hosts:\n'
    printf '        %s:\n          ansible_connection: community.docker.docker\n' $P-lb1 $P-lb2
    printf '    dns_clients:\n      hosts:\n'
    printf '        %s:\n          ansible_connection: community.docker.docker\n' $P-cliint $P-clipub
  } > lab-inventory.yml
  ;;
run)
  cd ansible || exit 1
  for run in 1 2; do ansible-playbook -i ../lab-inventory.yml -e @../tests/lab-vars.yml site.yml | sed -n '/PLAY RECAP/,$p'; done
  ansible-playbook -i ../lab-inventory.yml -e @../tests/lab-vars.yml \
    -e "{\"verify_client_vips\": {\"$P-cliint\": \"10.0.0.53\", \"$P-clipub\": \"203.0.113.53\"}}" \
    ../tests/verify.yml | sed -n '/PLAY RECAP/,$p'
  ;;
failover)
  q(){ docker exec $P-cliint sh -c "for i in 1 2 3 4; do dig ${1:-} +short +time=2 +tries=1 @10.0.0.53 who.lab.test TXT; done | sort | uniq -c | tr '\n' ' '"; echo; }
  vip(){ for n in 1 2; do docker exec $P-lb$n ip -br addr show eth0 | grep -q 10.0.0.53 && echo -n "lb$n "; done; }
  sleep 10   # let the per-source TCP connection rate (30 per 10 s) of earlier tests expire
  echo "VIP on: $(vip)  UDP: $(q) TCP: $(q +tcp)"
  echo "-- stop dnsdist on lb1"; docker exec $P-lb1 systemctl stop dnsdist; sleep 8
  echo "VIP on: $(vip)  UDP: $(q) TCP: $(q +tcp)"
  docker exec $P-lb1 systemctl start dnsdist; sleep 8; echo "-- dnsdist back: VIP on: $(vip)"
  echo "-- stop haproxy on lb1"; docker exec $P-lb1 systemctl stop haproxy; sleep 8
  echo "VIP on: $(vip)  UDP: $(q) TCP: $(q +tcp)"
  docker exec $P-lb1 systemctl start haproxy; sleep 8; echo "-- haproxy back: VIP on: $(vip)"
  echo "-- resolver2 down"; docker network disconnect $P-srv $P-resolver2; sleep 20   # 3 failed checks of 3 s each, 3 s apart
  echo "UDP: $(q) TCP: $(q +tcp)"
  docker network connect --ip 192.168.1.11 $P-srv $P-resolver2
  echo "-- per-IP UDP rate limit (dnsperf 5 s)"
  for r in 80 400; do echo "  internal -Q $r: $(docker exec $P-cliint sh -c "echo 'who.lab.test TXT' > /tmp/q; dnsperf -s 10.0.0.53 -d /tmp/q -l 5 -Q $r -t 1 2>/dev/null" | grep -E 'Queries (completed|lost)' | tr -s ' ' | tr '\n' ' ')"; done
  for r in 40 200; do echo "  public   -Q $r: $(docker exec $P-clipub sh -c "echo 'who.lab.test TXT' > /tmp/q; dnsperf -s 203.0.113.53 -d /tmp/q -l 5 -Q $r -t 1 2>/dev/null" | grep -E 'Queries (completed|lost)' | tr -s ' ' | tr '\n' ' ')"; done
  ;;
down)
  docker rm -f $P-lb1 $P-lb2 $P-cliint $P-clipub $P-resolver1 $P-resolver2 $P-resolver3 $P-auth1 $P-auth2 $P-auth3 >/dev/null
  docker network rm $P-int $P-pub $P-srv >/dev/null; rm -rf "$W" lab-inventory.yml
  ;;
*) echo "usage: $0 up|run|failover|down"; exit 1 ;;
esac
