#!/usr/bin/env bash

# --------------------------------------------------------------------------- #
#    Script that automates the installation of Privoxy and Squid.							#
#    Copyright (C) <2019>  <Homer Simpson @ PHCORNER.NET>											#
#																																							#
#    This program is free software: you can redistribute it and/or modify			#
#    it under the terms of the GNU General Public License as published by			#
#    the Free Software Foundation, either version 3 of the License, or				#
#    (at your option) any later version.																			#
#																																							#
#    This program is distributed in the hope that it will be useful,					#
#    but WITHOUT ANY WARRANTY; without even the implied warranty of						#
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the						#
#    GNU General Public License for more details.															#
#																																							#
#    You should have received a copy of the GNU General Public License				#
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.		#
#																																							#
#																																							#
# --------------------------------------------------------------------------- #

INSTALLER=$(basename $0)
OS_RELEASE_FILE="/etc/os-release"
OS=$(grep PRETTY_NAME $OS_RELEASE_FILE | cut -d'=' -f2 | cut -d' ' -f1 | tr -d '"')
OS_VERSION=$(grep VERSION_ID $OS_RELEASE_FILE | cut -d'=' -f2 | cut -d' ' -f1 | tr -d '"')
TARGET_OS=$(echo "$OS $OS_VERSION")
EXTERNAL_IP=
EXTERNAL_INT=
PACKAGES=( tmux firewalld mailx squid privoxy bash-completion wget curl openvpn unzip zip )
MYEMAIL=
ZONE=
CONFIRM=

get_email() {
  read -rp "Enter email: " MYEMAIL
  while ([[ -z $MYEMAIL ]]); do
    echo "Can't have an empty email address"
    read -rp "Enter email: " EMAIL
    done
    read -rp "Confirm (y/n): " CONFIRM
    while ([[ x$CONFIRM != 'xY' ]] && [[ x$CONFIRM != 'xy' ]]); do
      [[ x$CONFIRM == 'xN' ]] || [[ x$CONFIRM == 'xn' ]] && { $(get_email); break; }
      read -rp "Incorrect reply. Confirm (y/n): " CONFIRM
      done
}

menu() {
cat<<EOF

+--------------------------------------------------------+
|      SQUID & PRIVOXY installer by Homer Simpson        |
+--------------------------------------------------------+
You will be notified via email once the installation is complete.

EOF
  get_email
}

append_dns() {
  echo "Appending 1.1.1.1 and 1.0.0.1 into the DNS resolvers list..."
  if [[ $OS == "openSUSE" ]]; then
    sed -i 's/^\(NETCONFIG_DNS_STATIC_SERVERS="\)"/\11.1.1.1 1.0.0.1"/' /etc/sysconfig/network/config
  else
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf
  fi
}

easy_rsa() {
  wget -4qO /tmp/master.zip https://github.com/OpenVPN/easy-rsa/archive/master.zip
  unzip -d /tmp /tmp/master.zip
  cd /tmp/easy-rsa-master/easyrsa3
}


setup_network() {
  EXTERNAL_IP=$(curl -s4 http://ifconfig.me)
  EXTERNAL_INT=$(ip -4 route | grep default | head -1 | cut -d' ' -f5)
  echo "[EXTERNAL IP]: $EXTERNAL_IP"
  echo "[EXTERNAL INTERFACE]: "
  ZONE=$(firewall-cmd --get-zone-of-interface=$EXTERNAL_INT)
cat<<EOF
  EXTERNAL INTERFACE: $EXTERNAL_INT
  ZONE: $ZONE
  Allowing Privoxy:8118 and Squid:3128 ports into the firewall
  Please note that this might not be the most secure setup!
EOF
  firewall-cmd --quiet --permanent --zone=${ZONE} --remove-service=dhcpv6-client
  firewall-cmd --quiet --permanent --zone=${ZONE} --add-service=privoxy
  firewall-cmd --quiet --permanent --zone=${ZONE} --add-service=squid
  firewall-cmd --quiet --reload
  echo "Verifying if Privoxy and Squid ports have been successfully allowed through the the firewall..."
  echo -ne "[Allowed services]: " $(firewall-cmd --zone=${ZONE} --list-services) "\n"
}

# Install basic requisites
basic_reqs() {
  for i in ; do [[ $(which $i 2> /dev/null) ]]; [[ $? -eq 0 ]] && echo "$i found at $(which $i)" || { echo "$i is missing. Appending to install list..."; PACKAGES+=( $(echo $i ) ); }
  done
  echo -e "Packages candidate for installation: ${PACKAGES[@]}\nPlease wait...\n"
  $1 $(echo ${PACKAGES[@]})
  echo -e "\n\nAdjusting TIMEZONE to Manila/PH"; rm -rf /etc/localtime; ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
  if [[ ! $(grep "^\s*net.ipv6.conf.all.disable_ipv6 *= *1" /etc/sysctl.conf) ]]; then
    echo -e "Disabling IPv6...This will need a reboot\n"; echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
  fi
#  easy_rsa
}

setup_suse() {
  zypper update -y
  basic_reqs "zypper install -y"
}

setup_centos() {
  yum -y update
  yum -y install epel-release
  basic_reqs "yum -q install --assumeyes"
  sed -i 's/\(SELINUX=\).\+/\1permissive/' /etc/selinux/config
}

setup_debian() {
  apt-get update && apt-get upgrade -y
  basic_reqs "apt-get install -y"
}

setup_privoxy() {
  local PRIVOXY_CONFIG="/etc/privoxy/config"
  
  [[ -f $PRIVOXY_CONFIG ]] && { echo "Renaming the old config to ${PRIVOXY_CONFIG}.orig"; mv ${PRIVOXY_CONFIG}{,.orig}; }
cat>>${PRIVOXY_CONFIG}<<EOF
user-manual /usr/share/doc/privoxy/user-manual
confdir /etc/privoxy
logdir /var/log/privoxy
filterfile default.filter
logfile logfile
listen-address  0.0.0.0:8118
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 4096
enable-proxy-authentication-forwarding 1
forwarded-connect-retries  1
accept-intercepted-requests 1
allow-cgi-request-crunching 1
split-large-forms 0
keep-alive-timeout 5
tolerate-pipelining 1
socket-timeout 300
EOF
}

setup_squid() {
	local SQUID_CONFIG="/etc/squid/squid.conf"
  [[ -f $SQUID_CONFIG ]] && { echo "Renaming the old config to ${SQUID_CONFIG}.orig"; mv ${SQUID_CONFIG}{,.orig}; }
cat>>${SQUID_CONFIG}<<EOF
visible_hostname openBSD.vbox.internal.pacua.net
acl localnet src 192.168.0.0/16         # RFC 1918 local private network (LAN)
acl localnet src fc00::/7               # RFC 4193 local private network range
acl localnet src fe80::/10              # RFC 4291 link-local (directly plugged) machines
acl SSL_ports port 443
acl Safe_ports port 80          # http
acl Safe_ports port 21          # ftp
acl Safe_ports port 443         # https
acl Safe_ports port 70          # gopher
acl Safe_ports port 210         # wais
acl Safe_ports port 1025-65535  # unregistered ports
acl Safe_ports port 280         # http-mgmt
acl Safe_ports port 488         # gss-http
acl Safe_ports port 591         # filemaker
acl Safe_ports port 777         # multiling http
acl CONNECT method CONNECT
via off
forwarded_for delete
request_header_access Authorization allow all
request_header_access Proxy-Authorization allow all
request_header_access Cache-Control allow all
request_header_access Content-Length allow all
request_header_access Content-Type allow all
request_header_access Date allow all
request_header_access Host allow all
request_header_access If-Modified-Since allow all
request_header_access Pragma allow all
request_header_access Accept allow all
request_header_access Accept-Charset allow all
request_header_access Accept-Encoding allow all
request_header_access Accept-Language allow all
request_header_access Connection allow all
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Referer deny all
request_header_access All deny all
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access allow localnet
http_access allow localhost
http_access deny all
cache_peer 127.0.0.1 parent 8118 7 no-query no-digest default
cache deny all
EOF
}

post_install_check() {
  REPORT="/root/report.txt"
	echo "Performing post-install checks..."
  case "$TARGET_OS" in
    Debian*)
			dpkg -l $(echo ${PACKAGES[@]}) > $REPORT
			;;
    CentOS*)
			yum -q list installed $(echo ${PACKAGES[@]}) > $REPORT
      ;;
    openSUSE*)
			zypper se -itpackage $(echo ${PACKAGES[@]}) > $REPORT
      ;;
    esac
cat <<EOF>>$REPORT
    $(echo "Checking firewall...")
    $(echo -n "Allowed services: ")
    $(firewall-cmd --zone=${ZOME} --list-services)
    $(systemctl enable --now firewalld squid privoxy)
    $(systemctl restart --now firewalld squid privoxy)
    $(echo -e "\nChecking for listening ports")
    $(ss -4tlnp '( sport = :22 or sport = :8118 or sport = :3128 )')
EOF
}

mail_report() {
  MAILER=$(which mailx)
  $MAILER -s "Report of SQUID & PRIVOXY installation at $EXTERNAL_IP on $(date +%d-%b-%Y)" $MYEMAIL < $REPORT
}

main_func() {
  [[ $(whoami) != "root" ]] && { echo -e "This script needs to be run as root. Exiting...\n"; exit 1; }
  menu
  case "$TARGET_OS" in
    Debian*)
      echo "Distro: $TARGET_OS"
      setup_debian
      ;;
    CentOS*)
      echo "Distro: $TARGET_OS"
      setup_centos
      ;;
    openSUSE*)
      echo "Distro: $TARGET_OS"
      setup_suse
      ;;
    *)
      echo "Unknown distro. Exiting..."
      ;;
    esac

  setup_privoxy
  setup_squid
  setup_network
  append_dns
  post_install_check
  mail_report
}

main_func
echo -e "\nNow rebooting the machine now."
reboot
