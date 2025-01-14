#!/usr/bin/perl -w -I/www/cgi-bin
=for comment

  Part of AREDN -- Used for creating Amateur Radio Emergency Data Networks
  Copyright (C) 2015 Conrad Lara
   See Contributors file for additional contributors

  Copyright (c) 2013 David Rivenburg et al. BroadBand-HamNet

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation version 3 of the License.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.

  Additional Terms:

  Additional use restrictions exist on the AREDN(TM) trademark and logo.
    See AREDNLicense.txt for more info.

  Attributions to the AREDN Project must be retained in the source code.
  If importing this code into a new or existing project attribution
  to the AREDN project must be added to the source code.

  You must not misrepresent the origin of the material contained within.

  Modified versions must be modified to attribute to the original source
  and be marked in reasonable ways as differentiate it from the original
  version.

=cut

use perlfunc;

$| = 1;
$auto = 0;
$do_basic = 1;

sub usage
{
    die "
usage: node-setup [-a] [-p] <configname>
   -a: automatic mode - don't ask any questions
   -p: only process port forwarding and dhcp settings\n\n"
}

##########################
# main program starts here

# validate args
while(defined $ARGV[0] and $ARGV[0] =~ /^-/)
{
  $arg = shift;
  if   ($arg eq "-a") { $auto = 1 }
  elsif($arg eq "-p") { $do_basic = 0 }
  else                { usage() }
}

$config = shift;
usage() unless defined $config;

die "'$config' is not a valid configuration\n" unless ($config eq "mesh" and -f "/etc/config.mesh/_setup");

chomp ($lanintf=`jsonfilter -e '@.network.lan.ifname' < /etc/board.json | cut -f1`);
$node = nvram_get("node");
$tactical = nvram_get("tactical");
$mac2 = mac2ip(get_mac(get_interface("wifi")), 0);
$dtdmac = mac2ip(get_mac($lanintf), 0);

unless($auto)
{
  print "\ncurrent node name is '$node'\n";
  print "type a new name or just <enter> to keep the current name\n\n";

  do
  {
    print "enter node name: ";
    $node2 = <STDIN>;
    die "node-setup aborted\n" if not defined $node2;
    chomp $node2;
  }
  while($node2 =~ /[^\w\-]/ or $node2 =~ /_/);

  print "\ncurrent tactical name is ";
  if($tactical) { print "'$tactical'\n" }
  else          { print "not set\n" }

  print "type a new name, <enter> to keep the current name,\n";
  print "or @ to remove the tactical name\n\n";

  do
  {
    print "enter tactical name: ";
    $tac2 = <STDIN>;
    die "node-setup aborted\n" if not defined $tac2;
    chomp $tac2;
  }
  while($tac2 ne "@" and ($tac2 =~ /[^\w\-]/ or $tac2 =~ /_/));

  $node = $node2 if $node2;
  $tactical = $tac2 if $tac2;
  $tactical = "" if $tac2 eq "@";
}

#
# load and verify the selected configuration
#

foreach $line (`cat /etc/config.mesh/_setup`)
{
  next if $line =~ /^\s*#/;
  next if $line =~ /^\s*$/;
  $line =~ s/<NODE>/$node/;
  $line =~ s/<MAC2>/$mac2/;
  $line =~ s/<DTDMAC>/$dtdmac/;
  $line =~ /^(\w+)\s*=\s*(.*)$/;
  $cfg{$1} = $2;
}

chomp ($lanintf=`jsonfilter -e '@.network.lan.ifname' < /etc/board.json`);
$cfg{lan_intf} = "$lanintf";

$cfg{wan_intf} = "dummy";
# wan_intf is set by wifi-setup directly to network config file

$cfg{dtdlink_intf} = get_bridge_interfaces("dtdlink");

if ( $cfg{wifi_enable} == 1 )
{
  $cfg{wifi_intf} = `jsonfilter -e '@.network.wifi.ifname' < /etc/board.json | cut -f1`;
  $cfg{wifi_intf} =~ /wlan(\d+)/;
  chomp $cfg{wifi_intf};
}
else
{
  $wifi_sudo_intf = "$lanintf";
  $wifi_sudo_intf =~ s/^([^\. \t]+).*$/$1/;
  $cfg{wifi_intf} = $wifi_sudo_intf . ".3975";
}

die "configuration load failed\n" unless keys %cfg;

# delete some config lines if necessary
if($cfg{wan_proto} eq "dhcp")
{
  $deleteme{wan_ip} = 1;
  $deleteme{wan_gw} = 1;
  $deleteme{wan_mask} = 1;
}

$deleteme{lan_gw} = 1 if $cfg{dmz_mode} or $cfg{wan_proto} ne "disabled";


# lan_dhcp sense is inverted in the dhcp config file
# and it is a checkbox so it may not be defined - this fixes that
if($cfg{lan_dhcp}) { $cfg{lan_dhcp} = 0 }
else               { $cfg{lan_dhcp} = 1 }

# verify that we have all the variables we need
chdir "/etc/config.mesh" or die;
foreach(`grep "^[^#].*<" *`)
{
  ($file, $parm) = /^(\S+):.*<(\w+)>/;
  if($parm eq uc $parm) # nvram variable
  {
    $lcparm = lc $parm;
    die "parameter '$parm' in file '$file' does not exist\n" unless nvram_get($lcparm) ne "";
  }
  elsif(not $deleteme{$parm})
  {
    die "parameter '$parm' in file '$file' does not exist\n" unless exists $cfg{$parm};
  }
}

# switch to dmz values if needed
if($cfg{dmz_mode})
{
  foreach(qw(lan_ip lan_mask dhcp_start dhcp_end dhcp_limit))
  {
    $cfg{$_} = $cfg{"dmz_$_"};
  }
}

# select ports and dhcp files based on mode
$portfile  = "/etc/config.mesh/_setup.ports";
$dhcpfile  = "/etc/config.mesh/_setup.dhcp";
$portfile .= ($cfg{dmz_mode} ? ".dmz" : ".nat");
$dhcpfile .= ($cfg{dmz_mode} ? ".dmz" : ".nat");
$aliasfile = "/etc/config.mesh/aliases";
$aliasfile .= ($cfg{dmz_mode} ? ".dmz" : ".nat");

#check for old aliases file, copy it to .dmz and create symlink
#just in case anyone is already using the file for some script or something
unless(-l "/etc/config.mesh/aliases") {
  if(-f "/etc/config.mesh/aliases") {
    system "cat /etc/config.mesh/aliases > /etc/config.mesh/aliases.dmz";
    system "rm /etc/config.mesh/aliases";
    system "cd /etc/config.mesh ; ln -s aliases.dmz aliases";
  } else { system "cd /etc/config.mesh ; touch aliases.dmz ; ln -s aliases.dmz aliases"; }
}
# basic configuration

if($do_basic)
{
  # setup the staging area

  system "rm -rf /tmp/new_config; mkdir /tmp/new_config";

  # copy and process the new configuration

  chdir "/etc/config.mesh" or die;

  foreach $file (glob "*")
  {
    chomp $file;
    next if $file =~ /^_setup/;
    next if $file =~ /^firewall.user/;
    next if $file =~ /^olsrd/;

    open(IN, $file) or die;
    open(OUT, "> /tmp/new_config/$file") or die;

    while(defined ($line = <IN>))
    {
      if($line =~ /^include\s+(\S+)/)
      {
	${incs} = $1;
	
        foreach $inc (`cat ${incs}`)
        {
          print OUT $inc;
        }

        next;
      }

      $line =~ s/<NODE>/$node/;
      $line =~ s/<MAC2>/$mac2/;
      $line =~ s/<DTDMAC>/$dtdmac/;
      $delparm = 0;

      while(($parm) = $line =~ /^[^\#].*<(\S+)>/)
      {
        if($deleteme{$parm})
        {
          $delparm = 1;
          last;
        }
        $line =~ s/<$parm>/$cfg{$parm}/;
      }

      print OUT $line unless $delparm;
    }

    close(OUT);
    close(IN);
  }

  # make it official

  system "rm -f /etc/config/*";
  system "mv /tmp/new_config/* /etc/config";
  unlink "/tmp/new_config";
  system "cp -f /etc/config.mesh/firewall.user /etc/";

  nvram_set("config", "mesh");
  nvram_set("node", $node);
  nvram_set("tactical", $tactical);

}


#
# generate the system files
#

open(HOSTS, ">/etc/hosts") or die;
print HOSTS "# automatically generated file - do not edit\n";
print HOSTS "# use /etc/hosts.user for custom entries\n";
print HOSTS "127.0.0.1\tlocalhost\n";
print HOSTS "$cfg{lan_ip}\tlocalnode ";
print HOSTS "\n$cfg{wifi_ip}\t" if $cfg{wifi_ip};
print HOSTS "$node $tactical\n";
print HOSTS "$cfg{dtdlink_ip}\tdtdlink.$node.local.mesh dtdlink.$node\n" if $cfg{dtdlink_ip};
print HOSTS add_ip_address($cfg{lan_ip}, 1), "\tlocalap\n" unless $cfg{dmz_mode};

open(ETHER, ">/etc/ethers") or die;
print ETHER "# automatically generated file - do not edit\n";
print ETHER "# use /etc/ethers.user for custom entries\n";

$netaddr = ip2decimal($cfg{lan_ip}) & ip2decimal($cfg{lan_mask});

foreach(`cat $dhcpfile`)
{
  next if /^\s*#/;
  next if /^\s*$/;
  ($mac, $ip, $host, $noprop) = split /\s+/, $_;
  $ip = decimal2ip($netaddr + $ip);

  # filter out addresses that are illegal for the lan subnet
  next unless validate_same_subnet($ip, $cfg{lan_ip}, $cfg{lan_mask});
  next unless validate_ip_netmask($ip, $cfg{lan_mask});

  printf ETHER "$mac\t$ip $noprop\n";
  printf HOSTS "$ip\t$host $noprop\n";
}
#aliases need to be added to /etc/hosts or they will not show up on the localnode
#nor will the services they might offer
#also add a comment to the hosts file so we can display the aliases differently if needed
if(-e $aliasfile) {
  foreach(`cat $aliasfile`) {
    next if /^\s*#/;
    next if /^\s*$/;
    ($ip, $host) = split /\s+/, $_;
    printf HOSTS "$ip\t$host #ALIAS\n";
  }
}
print HOSTS "\n";
close(HOSTS);
close(ETHER);
system "cat /etc/hosts.user >> /etc/hosts" if -e "/etc/hosts.user";
system "cat /etc/ethers.user >> /etc/ethers" if -e "/etc/ethers.user";

unless($do_basic)
{
  system "cp -f /etc/config.mesh/firewall /etc/config";
  system "cp -f /etc/config.mesh/firewall.user /etc/";
}

open(FILE, ">>/etc/config/firewall") or die;

if($cfg{dmz_mode}) {
  print FILE "\nconfig forwarding\n";
  print FILE "        option src              wifi\n";
  print FILE "        option dest             lan\n";
  print FILE "\n";
  print FILE "\nconfig forwarding\n";
  print FILE "        option src              dtdlink\n";
  print FILE "        option dest             lan\n";

  system "uci set firewall.\@zone\[2\].masq=0";
} else  {
  print FILE "\n";
  print FILE "config 'include'\n";
  print FILE "        option 'path' '/etc/firewall.natmode'\n";
  print FILE "        option 'reload' '1'\n";
}


if ($cfg{olsrd_gw}) {
  print FILE "\nconfig forwarding\n";
  print FILE "        option src              wifi\n";
  print FILE "        option dest             wan\n";
  print FILE "\n";
  print FILE "\nconfig forwarding\n";
  print FILE "        option src              dtdlink\n";
  print FILE "        option dest             wan\n";
}

foreach(`cat $portfile`)
{
  next if /^\s*#/;
  next if /^\s*$/;
  chomp;

  # set dmz server
  if(/dmz_ip = (\S+)/ and not $cfg{dmz_mode})
  {
    print FILE "\nconfig redirect\n\toption src              wifi\n\toption proto            tcp\n\toption src_dip            $cfg{wifi_ip}\n\toption dest_ip          $1\n\n";
    print FILE "config redirect\n\toption src              wifi\n\toption proto            udp\n\toption src_dip            $cfg{wifi_ip}\n\toption dest_ip          $1\n\n";
    next;
  }

  # set port forwarding rule
  ($intf, $type, $oport, $host, $iport, $enable) = split /[:]/, $_;
  next unless $enable;

  if($cfg{dmz_mode})
  {
    next if $intf eq "wifi";
    $intf = "wan" if $intf eq "both";
  }

  $match = "option src_dport              $oport\n";

  if   ($type eq "tcp") { $match .= "option proto              tcp\n" }
  elsif($type eq "udp") { $match .= "option proto              udp\n" }

  # uci the host and than
  # set the inside port unless the rule uses an outside port range
  $host = "option dest_ip              $host\n";
  $host .="\toption dest_port              $iport\n" unless $oport =~ /-/;

  if($intf eq "both")
  {
    print FILE "\nconfig redirect\n\toption src              wifi\n\t$match\toption src_dip          $cfg{wifi_ip}\n\t$host\n";
    print FILE "\nconfig redirect\n\toption src              dtdlink\n\t$match\toption src_dip          $cfg{wifi_ip}\n\t$host\n";
    print FILE "config redirect\n\toption src              wan\n\t$match\t$host\n";
  }
  elsif($intf eq "wifi")
  {
    print FILE "\nconfig redirect\n\toption src              dtdlink\n\t$match\toption src_dip          $cfg{wifi_ip}\n\t$host\n";
    print FILE "config redirect\n\toption src              wifi\n\t$match\toption src_dip          $cfg{wifi_ip}\n\t$host\n";
  }
  elsif($intf eq "wan")
  {
    print FILE "\nconfig redirect\n\toption src              dtdlink\n\t$match\toption          src_dip $cfg{wifi_ip}\n\t$host\n";
    print FILE "config redirect\n\toption src              wan\n\t$match\t$host\n";
  }
  else
  {
    print STDERR "ERROR: unknown interface '$intf'\n";
    close(FILE);
    exit 1;
  }
}

close(FILE);


# generate the services file

$servfile = "/etc/config.mesh/_setup.services." . ($cfg{dmz_mode} ? "dmz" : "nat");
open(SERV, ">/etc/config/services") or die;
foreach(`cat $servfile 2>/dev/null`)
{
  next if /^\s*#/;
  next if /^\s*$/;
  chomp;
  ($name, $link, $proto, $host, $port, $suffix) = split /\|/, $_;
  $proto = "http" unless $proto;
  $port = 0 unless $link;
  $suffix = "" unless $suffix;
  next unless defined $name and $name ne "" and defined $host and $host ne "";
  printf SERV "%s://%s:%s/%s|%s|%s\n", $proto, $host, $port, $suffix, "tcp", $name;
}
close(SERV);

# generate the local config script

open(FILE, ">/etc/local/services") or die;
print FILE "#!/bin/sh\n";
unless($cfg{wifi_proto} eq "disabled")
{
  $cfg{wifi_txpower} = wifi_maxpower($cfg{wifi_channel}) if not defined $cfg{wifi_txpower} or $cfg{wifi_txpower} > wifi_maxpower($cfg{wifi_channel});
  $cfg{wifi_txpower} = 1  if $cfg{wifi_txpower} < 1;
  if ( $cfg{wifi_enable} == 1 )
  {
    print FILE "/usr/sbin/iw dev $cfg{wifi_intf} set txpower fixed $cfg{wifi_txpower}00\n";
  }
  if(defined $cfg{aprs_lat} and defined $cfg{aprs_lon})
  {
    printf FILE "echo %s,%s > /tmp/latlon.txt\n", $cfg{aprs_lat}, $cfg{aprs_lon};
  }
}
close(FILE);
system "chmod +x /etc/local/services";


# generate olsrd.conf

if(-f "/etc/config.mesh/olsrd")
{
  open(IN, "/etc/config.mesh/olsrd") or die;
  open(OUT, ">/etc/config/olsrd") or die;

  while(defined ($line = <IN>))
  {
    if($line =~ /<olsrd_bridge>/)
    {
      if($cfg{olsrd_bridge}) { $line =~ s/<olsrd_bridge>/"wifi" "lan"/ }
      else                   { $line =~ s/<olsrd_bridge>/"lan"/ }
    }
    elsif(($parm) = $line =~ /^[^\#].*<(\S+)>/)
    {
      $line =~ s/<$parm>/$cfg{$parm}/;
    }
    print OUT $line;
  }

  if($cfg{dmz_mode})
  {
    print OUT "\n";
    print OUT "config Hna4\n";
    @parts = split /[.]/, $cfg{dmz_lan_ip};
    --$parts[3]; # assume network = lan_ip - 1
    print OUT "\toption netaddr           ", join(".", @parts),"\n";
    print OUT "\toption netmask           255.255.255.", ((0xff << $cfg{dmz_mode}) & 0xff), "\n";
    print OUT "\n\n";
  }

  if($cfg{olsrd_gw})
  {


    print OUT "config LoadPlugin\n";
    print OUT "	option library 'olsrd_dyn_gw.so.0.5'\n";
    print OUT "	option Interval '60'\n";
    print OUT "	list Ping '8.8.8.8'\n";      # google dns\n";
    print OUT "	list Ping '8.8.4.4'\n";      # google dns\n";
    print OUT "\n\n";
  }

  close(OUT);
  close(IN);
}

# indicate whether lan is running in dmz mode
$cmd .= "uci -q set aredn.\@dmz[0].mode=$cfg{dmz_mode};";


# Setup node lan dhcp
if ( $cfg{lan_dhcp_noroute} ) {
  $cmd .= "uci add_list dhcp.\@dhcp[0].dhcp_option='121,10.0.0.0/8,$cfg{lan_ip},172.16.0.0/12,$cfg{lan_ip}' >/dev/null 2>&1;";
  $cmd .= "uci add_list dhcp.\@dhcp[0].dhcp_option='249,10.0.0.0/8,$cfg{lan_ip},172.16.0.0/12,$cfg{lan_ip}' >/dev/null 2>&1;";
  $cmd .= "uci add_list dhcp.\@dhcp[0].dhcp_option=3 >/dev/null 2>&1;";
} else {
  $cmd .= "uci add_list dhcp.\@dhcp[0].dhcp_option='121,10.0.0.0/8,$cfg{lan_ip},172.16.0.0/12,$cfg{lan_ip},0.0.0.0/0,$cfg{lan_ip}' >/dev/null 2>&1;";
  $cmd .= "uci add_list dhcp.\@dhcp[0].dhcp_option='249,10.0.0.0/8,$cfg{lan_ip},172.16.0.0/12,$cfg{lan_ip},0.0.0.0/0,$cfg{lan_ip}' >/dev/null 2>&1;";
}

# finish up

$cmd .= "uci -q commit;";
system $cmd;

#
# generate the wireless config file
#
system('/usr/local/bin/wifi-setup');

unless($auto)
{
  print "configuration complete.\n";
  print "you should now reboot the router.\n";
}

exit 0;
