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
	echo "Usage: ${0##*/} [--useragent <string>] [--port <number>] <hostname>"
  echo "  -h|--help        this help"
  echo "  -p|--port        443 is the default port if it is not specified"
  echo "  -u|--useragent   A User-Agent string to use."
  echo " The default is ${USERAGENT}"
  echo " openssl must be in your path"
  echo " trusted certs are assumed to be in ${BASE}/certs/"
  echo " trusted certs are assumed to be named {the actual hostname}.pem"
	exit 1
}

[[ $# -eq 0 || $1 =~ -h || $1 =~ \.\. || $1 =~ / ]] && usage
command -v openssl >/dev/null 2>/dev/null || usage

CAPATH="${BASE}/ca"
USERAGENT="Mozilla/5.0 (iPad; CPU OS 6_0 like Mac OS X) AppleWebKit/536.26(KHTML, like Gecko) Version/6.0 Mobile/10A5355d Safari/8536.25"
PORT=443

while [[ $# -gt 1 ]] ; do
  curr_arg="$1" ; shift
  if [[ $# -gt 0 ]] ; then next_arg="$1" ; shift ; else next_arg="" ; fi
  case "$curr_arg" in
    -u|--useragent) USERAGENT=$next_arg ;;
    -p|--port) PORT=$next_arg ;;
    -h|--help|help) usage ;;
  esac
done

HOST="$1"
CERT="${BASE}/certs/${HOST}.pem"

if [[ ! -s "${CERT}" ]] ; then
  echo "Missing or empty: ${CERT}"
  exit
fi

DUMP="${HOST}.dump"
REQUEST="${HOST}.request"

echo > "${REQUEST}" <<HTTP
GET / HTTP/1.1
User-Agent: ${USERAGENT}
Host: ${HOST}
Accept: */*

HTTP

report() {
  local _info="$1" ; shift

  while [[ $# -gt 0 ]] ; do
    [[ -n $1 ]] && _info="${_info} -- ${1}" ; shift
  done

  echo "${_info}"
}

_EXIT_CODE=1

if openssl s_client -crlf -connect "${HOST}:${PORT}" -showcerts -CApath "${CAPATH}" >& "${DUMP}" < "${REQUEST}" ; then
  TRUSTED=$(openssl x509 -fingerprint -in "${CERT}" -noout)
  REMOTE=$(openssl x509 -fingerprint -in "${DUMP}" -noout)
  CERT_CN=$(openssl x509 -in "${CERT}" -text -nameopt multiline -certopt no_header,no_version,no_serial,no_pubkey,no_sigdump,ext_default -noout | tr -d '\n' | sed -e 's/^.*Issuer:.*Subject:.*commonName  *=  *\([^ ]*\)  *.*$/\1/')
  CERT_CN_REGEX=$(echo "${CERT_CN}" | sed -e 's/\./\\./g' -e 's/\*/.*/')
  CERT_CN_CHECK=$(echo $HOST | grep -cE "${CERT_CN_REGEX}")
  CERT_DNS=$(openssl x509 -in "${CERT}" -text -nameopt multiline -certopt no_header,no_version,no_serial,no_pubkey,no_sigdump,ext_default -noout | grep 'DNS:' | sed -e 's/DNS://g' -e 's/^  *//' -e 's/,//g')
  CERT_DNS_REGEX=""
  CERT_DNS_CHECK=""
  CN_INFO=""
  DNS_INFO=""

  if [[ -n $CERT_DNS ]] ; then
    CERT_DNS_REGEX=$(echo "${CERT_DNS}" | sed -e 's/\./\\./g' -e 's/\*/.*/g' -e 's/  */|/g')
    CERT_DNS_CHECK=$(echo $HOST | grep -cE "${CERT_DNS_REGEX}")
  fi

  if [[ $CERT_CN_CHECK == 0 && (-z $CERT_DNS || -n $CERT_DNS && $CERT_DNS_CHECK == 0)  ]] ; then
    CN_INFO="Hostname doesn't match commonName: ${HOST} != ${CERT_CN}"
  fi

  if [[ -n $CERT_DNS && $CERT_DNS_CHECK == 0 ]] ; then
    DNS_INFO="Hostname doesn't match subjectAltName DNS entries: ${HOST} !~ ${CERT_DNS}"
  fi

  if [[ $TRUSTED == $REMOTE ]] ; then
    report "OK" "$CN_INFO" "$DNS_INFO"
    _EXIT_CODE=0
  elif [[ -n $CN_INFO && -n $DNS_INFO ]] ; then
    report "Probable Captured Network" "$CN_INFO" "$DNS_INFO"
    _EXIT_CODE=0
  else
    report "Possible SSL M-I-T-M: ${TRUSTED} != ${REMOTE}" "$CN_INFO" "$DNS_INFO"
  fi

else
  cat "${DUMP}"
fi

[[ -f "${DUMP}" ]] && rm "${DUMP}"
[[ -f "${REQUEST}" ]] && rm "${REQUEST}"

exit $_EXIT_CODE

