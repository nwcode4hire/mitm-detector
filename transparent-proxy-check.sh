#!/usr/bin/env bash

BASE=$(
  prg=$0
  case $prg in
    (*/*) ;;
    (*) [ -e "$prg" ] || prg=$(command -v -- "$0")
  esac
  cd -P -- "$(dirname -- "$prg")" && pwd -P
)

usage() {
	echo "Usage: ${0##*/} [-v -v ...] [-e <number>] [-p <number>] [-c passphrase] [-s hostname]"
  echo "  -h   this help text"
  echo "  -v   be verbose/debuggy.  Extra -v's hypothetically increase verbosity."
  echo "  -e   59031 is the default echo-port if it is not specified"
  echo "  -p   80 is the default port tested for transparent proxies"
  echo "  -s   mitm-check.chorn.com is the default echo-server if it is not specified"
  echo "  -c   mitm-check is the default passphrase, and the one you have to use for mitm-check.chorn.com."
  echo " nping, dig, tcpdump, dig, and curl must all be in your path, and you'll need sudo privs"
	exit 1
}

d() {
  local _level=$1
  local
}

for com in nping dig tcpdump dig curl ; do
  command -v "$com" >/dev/null 2>/dev/null || usage
done

declare echo_server="mitm-check.chorn.com"
declare -i echo_port=59031
declare -i port=80
declare passphrase="mitm-check"
declare -i total=25
declare -i verbose=0 # off

while getopts ":h :v :e: :p: :s: :c:" opt; do
    case $opt in
      h|\?|:) usage ;;
      v) verbose+=1 ;;
      e) echo_port=$OPTARG ;;
      p) port=$OPTARG ;;
      s) echo_server=$OPTARG ;;
      c) passphrase=$OPTARG ;;
  esac
done

gateway=""
interface=""

local_nameserver=$(/usr/bin/grep '^ *nameserver' /etc/resolv.conf | head -1 | sed -e 's/[^0-9\.]//g')
opendns="@208.67.222.222"
nameserver=$opendns

if [ -n $local_nameserver ] ; then
  nameserver=$local_nameserver
fi

internet_ip=$(dig +short $nameserver myip.opendns.com)

if [ -z $internet_ip ] ; then
  internet_ip=$(curl -4s checkip.dyndns.org | sed -e 's/[^0-9\.]//g')
fi

if [ -z $internet_ip ] ; then
  echo "I can't seem to get your external internet IP.  I've tried:"
  echo dig +short $nameserver myip.opendns.com
  dig +short $nameserver myip.opendns.com
  echo "and:"
  echo curl -4s checkip.dyndns.org
  curl -4s checkip.dyndns.org
  echo but neither worked.
  echo "Could you open an issue here: https://github.com/chorn/mitm-detector/issues"
  echo "and include this log.  Thank you!"
fi

server_ip=$(dig +short $nameserver $echo_server)

if [[ -z $server_ip ]] ; then
  echo "I can't get the IP address for $echo_server."
fi

if [ "${OSTYPE:0:6}" = "darwin" ] ; then
  gateway=$(route -n get default | grep gateway | sed -e 's/^.*: //')
  interface=$(route -n get default | grep interface | sed -e 's/^.*: //')
else
  gateway=$(ip route list | grep 'default via' | sed -e 's/^default via //' -e 's/ .*//')
  interface=$(ip route list | grep 'default via' | sed -e 's/^.*dev //')
fi

local_ip=$(ifconfig $interface | grep 'inet ' | sed -e 's/^.*inet //' -e 's/addr://' -e 's/ .*$//')
declare -i private_ip=$("$BASE/private-ip-check.sh" $local_ip)

if [[ $verbose -gt 0 ]] ; then
  echo "Local Nameserver:  $local_nameserver"
  echo "Using Nameserver:  $nameserver"
fi

if [[ $verbose -gt 1 ]] ; then
  echo -n "Dependencies:     "
  for com in nping dig tcpdump dig curl ; do
    echo -n " $(which $com)"
  done
  echo ""
fi

echo "Default Gateway:   $gateway"
echo "Default Interface: $interface"

declare -i target=$(($total))

if [[ $private_ip -eq 0 ]] ; then
  echo "IPv4 Local:        $local_ip (Private Network Block, assuming NAT)"
  let target--
elif [[ $local_ip != $internet_ip ]] ; then
  echo "IPv4 Local:        $local_ip (Your external IP is different)"
  let target--
fi

echo "IPv4 Internet:     $internet_ip"

if [[ $verbose -gt 0 ]] ; then
  echo "Echo server:       $echo_server"
  echo "Echo server IP:    $server_ip"
  echo "Echo passphrase:   $passphrase"
  echo "Echo port:         $echo_port"
  echo "Test port:         $port"
fi

# sudo nmap --traceroute -n -T4 mitm-check.chorn.com -p 80

params=(
--echo-client "$passphrase"
--echo-port $echo_port
--tcp
-p $port
-c $total
-v2
$echo_server
)
# --bpf-filter "((src host $local_ip and dst host $echo_server) or (src host $echo_server and dst host $local_ip)) and tcp and not port $echo_port"

if [[ $verbose -gt 2 ]] ; then
  echo "Initial nping command: sudo nping ${params[@]}"
  #2>nping.stderr | sed -e "s/^\([A-Z]*\) (.*) TCP \[\([0-9\.]*\):[0-9]* > \([0-9\.]*\):[0-9]* \([A-Z]*\) .*$/\1 \2 \3 \4/" -e "s/${internet_ip//./\\.}/INTERNET_IP/" -e "s/${local_ip//./\\.}/LOCAL_IP/" -e "s/${server_ip//./\\.}/SERVER_IP/" -e "s/${gateway_ip//./\\.}/GATEWAY_IP/")
fi

echo "Running nping echo-client (requires sudo), this should take about $total seconds..."

# Did we lose any packets?
declare -i lost
declare -a sent
declare -a capt
declare -a rcvd

while read line ; do
  if [[ $verbose -gt 3 ]] ; then
    echo "$line"
  fi
  case ${line} in
  (SENT*) sent+=("$line") ;;
  (CAPT*) capt+=("$line") ;;
  (RCVD*) rcvd+=("$line") ;;
  (Raw*)
    snip=${line/*Lost: /}
    lost=${snip/ */}
    ;;
  (*) ;;
esac
done < <(sudo nping ${params[@]} 2>nping.stderr | sed -e "s/^\([A-Z]*\) (.*) TCP \[\([0-9\.]*\):[0-9]* > \([0-9\.]*\):[0-9]* \([A-Z]*\) .*$/\1 \2 \3 \4/" -e "s/${internet_ip//./\\.}/INTERNET_IP/" -e "s/${local_ip//./\\.}/LOCAL_IP/" -e "s/${server_ip//./\\.}/SERVER_IP/" -e "s/${gateway_ip//./\\.}/GATEWAY_IP/")

[[ $! ]] && cat nping.stderr
[[ -f nping.stderr ]] && sudo rm nping.stderr

echo ${sent[@]} ${rcvd[@]} ${capt[@]} | grep '[0-9]'

declare ok=0

if [[ ${#sent[@]} -eq $total ]] ; then
  let ok++
else
  echo "SENT should be $total, observed ${#sent[@]}:"
  for line in "${sent[@]}" ; do echo $line ; done
fi

if (( ${#rcvd[@]} == ($total - $lost) )) ; then
  let ok++
else
  echo "RCVD should be $total, observed ${#rcvd[@]}:"
  for line in "${rcvd[@]}" ; do echo $line ; done
fi

if [[ ${#capt[@]} -ge $target ]] ; then
  let ok++
else
  echo "CAPT should be at least $target, observed ${#capt[@]}:"
  for line in "${capt[@]}" ; do echo $line ; done
fi

if [[ $ok -eq 3 ]] ; then
  echo "OK"
elif [[ $ok -eq 2 ]] ; then
  echo "There might be a transparent proxy? Run this again and compare the results."
  echo ${sent[@]} ${rcvd[@]} ${capt[@]} | grep '[0-9]'
else
  echo "Something is misconfigured, unreachable, or weird.  Testing with count == $total for packets loss. Hopefully any packet loss matches the unmatched RCVD/CAPT counts."
  ping -c $total $echo_server
fi


