#!/usr/bin/perl
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

$debug = 0;

BEGIN {push @INC, '/www/cgi-bin'};
use perlfunc;
use ucifunc;

$config = nvram_get("config");
$node = nvram_get("node");
$node = "NOCALL" if $node eq "";
$tactical = nvram_get("tactical");

read_postdata();

if($config ne "mesh" or -e "/tmp/reboot-required")
{
    http_header();
    html_header("$node setup", 1);
    print "<body><center><table width=790><tr><td>\n";
    alert_banner();
    navbar("ports");
    print "</td></tr><tr><td align=center><br><b>";
    if($config eq "")
    {
	print "This page is not available until the configuration has been set.";
    }
    else
    {
	print "The specified configuration is invalid, try flushing your browser cache or reboot the mesh node.\n";
    }
    print "</b></td></tr>\n";
    print "</table></center>";
    page_footer();
    print "</body></html>\n";
    exit;
}

# check for dmz mode
chomp(my $dmz_mode = `/sbin/uci -q get aredn.\@dmz[0].mode`);

# get the network details of the lan interface for dhcp calculations

($lanip, $lanmask, $junk, $lannet, $lancidr) = get_ip4_network(get_interface("lan"));

$lannet_d = ip2decimal($lannet);

$tmpdir = "/tmp/web/ports";
system "rm -rf $tmpdir" unless $parms{reload};
system "mkdir -p $tmpdir";

$portfile  = "/etc/config.mesh/_setup.ports";
$dhcpfile  = "/etc/config.mesh/_setup.dhcp";
$servfile  = "/etc/config.mesh/_setup.services";
$aliasfile = "/etc/config.mesh/aliases";

my $suffix = $dmz_mode ? ".dmz" : ".nat";
$portfile .= $suffix;
$dhcpfile .= $suffix;
$servfile .= $suffix;
$aliasfile .= $suffix;

# if a reset or a first time page load
# read the data from the config files
if($parms{button_reset} or not $parms{reload})
{
    $i = 0;
    foreach(`cat $portfile 2>/dev/null`)
    {
	next if /^\s*#/;
	next if /^\s*$/;
	chomp;

	# set parameters
	if(/(\S+)\s+=\s+(\S+)/)	{ $parms{$1} = $2; next; }

	# set port forwarding rules
	@parts = split /[:]/, $_;
	next unless scalar(@parts) == 6;
	++$i;

	#foreach $var (qw(intf type out ip in enable adv link proto suffix name))
	foreach $var (qw(intf type out ip in enable))
	{
	    $parms{"port${i}_$var"} = shift @parts;
	}
    }
    $parms{port_num} = $i;

    # set dhcp reservations
    # ip addresses are stored as offsets from the lan network address

    $i = 0;
    foreach(`cat $dhcpfile 2>/dev/null`)
    {
	next if /^\s*#/;
	next if /^\s*$/;
	chomp;
	@parts = split /\s+/, $_;
	if (!defined $parts[3]) {
          $parts[3] = '';
        }
	next unless scalar(@parts) == 4;
	++$i;
	$parms{"dhcp${i}_host"} = $parts[2];
	$parms{"dhcp${i}_ip"}   = add_ip_address($lannet, $parts[1]);
	$parms{"dhcp${i}_mac"}  = $parts[0];
	$parms{"dhcp${i}_noprop"} = $parts[3];
    }
    $parms{dhcp_num} = $i;

    # services

    $i = 0;
    foreach(`cat $servfile 2>/dev/null`)
    {
	next if /^\s*#/;
	next if /^\s*$/;
	chomp;
	@parts = split /\|/, $_;
	$parts[5] = "" unless $parts[5];
	next unless scalar(@parts) == 6;
	++$i;
	foreach $var (qw(name link proto host port suffix))
	{
	    $parms{"serv${i}_$var"} = shift @parts;
	}
    }
    $parms{serv_num} = $i;

    #aliases
    $i = 0;
    foreach(`cat $aliasfile 2>/dev/null`)
    {
	next if /^\s*#/;
	next if /^\s*$/;
	chomp;
	@parts = split /\s+/, $_;
	next unless scalar(@parts) == 2;
	++$i;
	$parms{"alias${i}_host"} = $parts[1];
	$parms{"alias${i}_ip"}   = $parts[0];
    }
    $parms{alias_num} = $i;

    # sanitize the "add" values
    $parms{port_add_intf} = $dmz_mode ? "wan" : "wifi";
    $parms{port_add_type} = "tcp";
    $parms{dmz_ip} = "" unless defined $parms{dmz_ip};

    foreach $var (qw(port_add_out port_add_ip port_add_in dhcp_add_host dhcp_add_ip dhcp_add_mac dhcp_add_noprop serv_add_name serv_add_proto serv_add_host serv_add_port serv_add_suffix alias_add_host alias_add_ip))
    {
	$parms{$var} = "";
    }
}

# get the dhcp range
# assume that the lan setup is the only one that exists
($rc, $dhcp_start) = &uci_get_indexed_option("dhcp","dhcp","0","start");
($rc, $dhcp_limit) = &uci_get_indexed_option("dhcp","dhcp","0","limit");
$dhcp_end = $dhcp_start + $dhcp_limit - 1;

#
# load and validate the ports
#

for($i = 1, @list = (); $i <= $parms{port_num}; ++$i) { push @list, $i }
push @list, "_add";
$port_num = 0;
open(FILE, ">$tmpdir/ports");

foreach $val (@list)
{
    # load strings
    foreach $var (qw(intf type out ip in))
    {
	$varname = "port${val}_$var";
	$parms{$varname} = "" unless $parms{$varname};
	$parms{$varname} =~ s/^\s+//;
	$parms{$varname} =~ s/\s+$//;
	eval sprintf("\$%s = \$parms{%s}", $var, $varname);
    }

    # load bools
    foreach $var (qw(enable))
    {
	$varname = "port${val}_$var";
	$parms{$varname} = 0 unless $parms{$varname};
	eval sprintf("\$%s = \$parms{%s}", $var, $varname);
    }

    $enable = 1 if $val eq "_add";

    if($val eq "_add") { next unless ($out or $ip or $in) and ($parms{port_add} or $parms{button_save}) }
    else               { next if $parms{"port${val}_del"} }

    if($val eq "_add" and $parms{button_save})
    {
	push(@port_err, "$val this rule must be added or cleared out before saving changes");
	next;
    }

    if($out =~ /-/) # this is a port range
    {
	if(validate_port_range($out))
	{
	    $out =~ s/\s+//;
	    ($in) = $out =~ /^(\d+)/; # force inside to match outside
	}
	else
	{
	    push(@port_err, "$val '$out' is not a valid port range");
	}
    }
    else
    {
	if($out eq "") { push @port_err, "$val an outside port is required" }
	else           { push(@port_err, "$val '$out' is not a valid port") unless validate_port($out) }
    }

    if($ip eq "")               { push @port_err, "$val an address must be selected" }
    elsif(not validate_ip($ip)) { push @port_err, "$val '$ip' is not a valid address" }

    if($in eq "") { push @port_err, "$val a LAN port is required" }
    else          { push(@port_err, "$val '$in' is not a valid port") unless validate_port($in) }
    next if $val eq "_add" and @port_err and $port_err[-1] =~ /^_add /;

    # commit the data for this rule
    ++$port_num;
    $usedports{$out} = 1;
    $type = "both" unless $type eq "tcp" or $type eq "udp";
    print FILE "$intf:$type:$out:$ip:$in:$enable\n";

    foreach $var (qw(intf type out ip in enable))
    {
	eval sprintf("\$parms{port%d_%s} = \$%s", $port_num, $var, $var);
    }

    if($val eq "_add")
    {
	$parms{port_add_intf} = "wifi";
	$parms{port_add_out} = "";
	$parms{port_add_ip} = "";
	$parms{port_add_in} = "";
    }
}

if($parms{dmz_ip})
{
    print FILE "dmz_ip = $parms{dmz_ip}\n";
    push(@dmz_err, "'$parms{dmz_ip}' is not a valid address") unless validate_ip($parms{dmz_ip});
}

close(FILE);
$parms{port_num} = $port_num;


#
# load and validate the dhcp reservations
#

for($i = 1, @list = (); $i <= $parms{dhcp_num}; ++$i) { push @list, $i }
push @list, "_add";
$dhcp_num = 0;

foreach $val (@list)
{
    $host = $parms{"dhcp${val}_host"};
    $ip   = $parms{"dhcp${val}_ip"};
    $mac  = $parms{"dhcp${val}_mac"};
    $noprop = $parms{"dhcp${val}_noprop"};
    $foundHost = 0;
    if($val eq "_add")
    {
	if($host) {
		#my $foundHost = 0;
		my $olsrFile = 0;
        	$olsrFile = 1 if -f "/var/run/hosts_olsr";
        	if($olsrFile) {
			open(my $hostFile, "<", "/var/run/hosts_olsr");
			while(<$hostFile>) {
            			if($_ =~ /\s$host\s/i) {
					$foundHost = 1;
              				last;
            			}
          		}
         		close($hostFile);
         		push(@dhcp_err, "$val <font color='red'>Warning!</font> '$host' is already in use!<br>" .
         		"Please choose another hostname.<br>" .
            		"Prefixing the hostname with your callsign will help prevent duplicates on the network.") if $foundHost == 1;
        	}
	}
	next unless ($host or $ip or $mac or $foundHost) and ($parms{dhcp_add} or $parms{button_save});
    }
    else
    {
	next if $parms{"dhcp${val}_del"};
    }

    if($val eq "_add" and $parms{button_save})
    {
	push @dhcp_err, "$val this reservation must be added or cleared out before saving changes";
	next;
    }

    if(validate_hostname($host))
    {
	if(! $foundHost) {
		push(@dhcp_err, "$val hostname '$host' is already in use") if (lc $host eq lc $node || lc $host eq lc $tactical);
        	foreach my $key (keys %hosts) {
           		if ( lc $key eq lc $host ){
               			push(@dhcp_err, "$val hostname '$host' is already in use");
               			last;
           		}
        	}
	}
    }
    else
    {
	if($host) { push @dhcp_err, "$val '$host' is not a valid hostname" }
	else      { push @dhcp_err, "$val a hostname is required" }
    }

    if(validate_ip($ip))
    {
	if($addrs{$ip})
	{
	    push(@dhcp_err, "$val $ip is already in use");
	}
	elsif($ip eq $lanip or
	   not validate_same_subnet($ip, $lanip, $lanmask) or
	   not validate_ip_netmask($ip, $lanmask))
	{
	    push @dhcp_err, "$val '$ip' is not a valid LAN address";
	}
    }
    else
    {
	if($ip) { push @dhcp_err, "$val '$ip' is not a valid address" }
	else    { push @dhcp_err, "$val an IP Address must be selected" }
    }

    if(validate_mac($mac))
    {
	push(@dhcp_err, "$val MAC $mac is already in use") if $macs{$mac};
    }
    else
    {
	if($mac) { push @dhcp_err, "$val '$mac' is not a valid mac address" }
	else     { push @dhcp_err, "$val a MAC Address is required" }
    }

    next if $val eq "_add" and @dhcp_err and $dhcp_err[-1] =~ /^$val /;

    # commit the data for this reservation
    ++$dhcp_num;
    #print FILE "$mac $ip $host\n";
    $parms{"dhcp${dhcp_num}_host"} = $host;
    $parms{"dhcp${dhcp_num}_ip"}   = $ip;
    $parms{"dhcp${dhcp_num}_mac"}  = $mac;
    $parms{"dhcp${dhcp_num}_noprop"} = $noprop;

    $hosts{$host} = 1;
    $addrs{$ip} = 1;
    $macs{$mac} = 1;

    if($val eq "_add")
    {
	$parms{dhcp_add_host} = "";
	$parms{dhcp_add_ip}   = "";
	$parms{dhcp_add_mac}  = "";
        $parms{dhcp_add_noprop} = "";
    }
}

# add existing leases
foreach $lease (keys %parms)
{
    #$hosts{$parms{$lease}} = 1 if $lease =~ /^lease\d+_host$/;
    next unless ($n) = $lease =~ /^lease(\d+)_add$/;
    next unless $parms{$lease};

    # eliminate duplicate mac addresses
    $found = 0;
    foreach(keys %parms)
    {
	next unless /dhcp\d+_mac/;
	$found = 1 if $parms{$_} eq $parms{"lease${n}_mac"};
    }
    next if $found;

    ++$dhcp_num;
    $host = $parms{"lease${n}_host"};
    $ip   = $parms{"lease${n}_ip"};
    $mac  = $parms{"lease${n}_mac"};
    $noprop = $parms{"lease${n}_noprop"};

    $parms{"dhcp${dhcp_num}_host"} = $host;
    $parms{"dhcp${dhcp_num}_ip"}   = $ip;
    $parms{"dhcp${dhcp_num}_mac"}  = $mac;
    $parms{"dhcp${dhcp_num}_noprop"} = $noprop;

    push(@dhcp_err, "$dhcp_num hostname '$host' is already in use") if (lc $host eq lc $node || lc $host eq lc $tactical);
    foreach my $key (keys %hosts) {
        if ( lc $key eq lc $host ){
            push(@dhcp_err, "$dhcp_num hostname '$host' is already in use");
            last;
        }
    }
    push(@dhcp_err, "$dhcp_num $ip is already in use")              if $addrs{$ip};
    push(@dhcp_err, "$dhcp_num MAC $mac is already in use")         if $macs{$mac};
    last;
}

$parms{dhcp_num} = $dhcp_num;
$dhcphosts{$lanip} = "localnode";

# replace "blank" dhcp hostnames and save the dhcp info into the tmpdir
open(FILE, ">$tmpdir/dhcp");
for($i = $nn = 1; $i <= $parms{dhcp_num}; $i++)
{
    if($parms{"dhcp${i}_host"} eq "*")
    {
	while(exists $hosts{"noname$nn"}) { $nn++ }
	$parms{"dhcp${i}_host"} = "noname$nn";
	$hosts{"noname$nn"} = 1;
    }
    printf FILE "%s %d %s %s\n",
           $parms{"dhcp${i}_mac"},
           ip2decimal($parms{"dhcp${i}_ip"}) - $lannet_d,
           $parms{"dhcp${i}_host"},
           $parms{"dhcp${i}_noprop"};

    # save it in a lookup table
    $dhcphosts{$parms{"dhcp${i}_ip"}} = $parms{"dhcp${i}_host"} unless $dhcphosts{$parms{"dhcp${i}_ip"}};
}
close(FILE);

#
# aliases
#
for($i = 1, @list = (); $i <= $parms{alias_num}; ++$i) { push @list, $i }
push @list, "_add";
$alias_num = 0;
foreach $val (@list) {
    $host = $parms{"alias${val}_host"};
    $ip   = $parms{"alias${val}_ip"};
    #if adding alias check the name is not already in use,
    #also check that it does not contain anything that will be weird on the mesh
    #for instance: supercoolservice.kg6wxc-host.local.mesh is certainly a valid host name, but it won't work for the mesh.
    if($val eq "_add") {
        if($host) {
            my $olsrFile = 0;
        	$olsrFile = 1 if -f "/var/run/hosts_olsr";
        	if($olsrFile) {
                open(my $hostFile, "<", "/var/run/hosts_olsr");
                while(<$hostFile>) {
            		if($_ =~ /\s$host\s/i) {
                        $foundHost = 1;
              			last;
                    }
          		}
                close($hostFile);
         		push(@alias_err, "$val <font color='red'>Warning!</font> '$host' is already in use!<br>" .
         		"Please choose another alias name.<br>" .
            	"Prefixing the hostname with your callsign will help prevent duplicates on the network.") if $foundHost == 1;
        	}
        	push(@alias_err, "$val <font color='red'>Warning!</font> The alias name: '$host' is invalid") if !validate_hostname($host);
            push(@alias_err, "$val '$host' cannot contain the dot '.' character!") if index($host, ".") != -1;
        }
        next unless ($host or $ip or $foundHost) and ($parms{alias_add} or $parms{button_save});
    } else {
        next if $parms{"alias${val}_del"};
    }
    if($val eq "_add" and $parms{button_save}) {
        push(@alias_err, "$val this alias must be added or cleared out before saving changes");
        next;
    }
    next if $val eq "_add" and @alias_err and $alias_err[-1] =~ /^$val /;
    # commit the data for this alias
    ++$alias_num;
    $parms{"alias${alias_num}_host"} = $host;
    $parms{"alias${alias_num}_ip"}   = $ip;
    $hosts{$host} = 1;
    if($val eq "_add") {
        $parms{alias_add_host} = "";
        $parms{alias_add_ip}   = "";
    }
}
#write to temp file
open(FILE, ">$tmpdir/aliases");
for($i = 1, @list = (); $i <= $alias_num; ++$i) {
    printf FILE "%s %s\n", $parms{"alias${i}_ip"}, $parms{"alias${i}_host"};
}
close(FILE);
$parms{alias_num} = $alias_num;

#
# load and validate the services
#

for($i = 1, @list = (); $i <= $parms{serv_num}; ++$i) { push @list, $i }
push @list, "_add";
$serv_num = 0;
$hosts{""} = 1;
$hosts{$node} = 1;
$usedports{""} = 1;
open(FILE, ">$tmpdir/services");

foreach $val (@list)
{
    foreach $var (qw(name proto host port suffix))
    {
	$varname = "serv${val}_$var";
	$parms{$varname} = "" unless $parms{$varname};
	$parms{$varname} =~ s/^\s+//;
	$parms{$varname} =~ s/\s+$//;
	eval sprintf("\$%s = \$parms{%s}", $var, $varname);
    }

    $host = $node unless $dmz_mode;

    # remove services that have had their host or port deleted
    #next if $val ne "_add" and not ($dmz_mode ? $hosts{$host} : $usedports{$port});
    next if $val ne "_add" and not ($dmz_mode ? $hosts{$host} : 1 );

    $link = $parms{"serv${val}_link"};
    $link = 0 unless $link;

    if($val eq "_add")
    {
	next unless ($name or $proto or $port or $suffix) and ($parms{serv_add} or $parms{button_save})
    }
    else
    {
	next if $parms{"serv${val}_del"} or not ($name or $proto or $port or $suffix);
    }

    if($val eq "_add" and $parms{button_save})
    {
	push @serv_err, "$val this service must be added or cleared out before saving changes";
	next;
    }

    if($name eq "")
    {
	push @serv_err, "$val a name is required";
    }
    else
    {
	push(@serv_err, "$val '$name' is not a valid service name") unless validate_service_name($name);
	push(@serv_err, "$val the name '$name' is already in use") if $servicenames{$name};
    }

    if($link)
    {
	$parms{"serv${val}_proto"} = $proto = "http" unless $proto;
	#$port = 80 if $proto eq "http" and not $port;
	push(@serv_err, "$val '$proto' is not a valid service protocol") unless validate_service_protocol($proto);
	if($port eq "") { push @serv_err, "$val a port number is required" }
	else            { push(@serv_err, "$val '$port' is not a valid port") unless validate_port($port) }
	push(@serv_err, "$val '$suffix' is not a valid service suffix") unless validate_service_suffix($suffix);
    }
    elsif($val eq "_add")
    {
	$proto = $port = $suffix = "";
    }

    next if $val eq "_add" and @serv_err and $serv_err[-1] =~ /^_add /;

    # commit the data for this service
    ++$serv_num;
    $servicenames{$name} = 1;
    print FILE "$name|$link|$proto|$host|$port|$suffix\n";

    foreach $var (qw(name link proto host port suffix))
    {
	eval sprintf("\$parms{serv%d_%s} = \$%s", $serv_num, $var, $var);
    }

    if($val eq "_add")
    {
	foreach(qw(name link proto host port suffix)) { $parms{"serv_add_$_"} = "" }
    }
}

close(FILE);
$parms{serv_num} = $serv_num;

#
# save configuration
#

if($parms{button_save} and not (@port_err or @dhcp_err or @dmz_err or @serv_err or @alias_err))
{
    system "cp -f $tmpdir/ports $portfile";
    system "cp -f $tmpdir/dhcp $dhcpfile";
    system "cp -f $tmpdir/services $servfile";
    system "cp -f $tmpdir/aliases $aliasfile";

    push(@errors, "problem with configuration")  if system "/usr/local/bin/node-setup.pl -a -p mesh";

    unless($debug == 3)
    {
	push(@errors, "problem with dnsmasq")    if system "/etc/init.d/dnsmasq reload >/dev/null 2>&1";
	push(@errors, "problem with port setup") if system "/etc/init.d/firewall reload >/dev/null 2>&1";
        push(@errors, "problem with olsr setup") if system "/etc/init.d/olsrd restart >/dev/null 2>&1";
    }
}


#
# generate the page
#

http_header() unless $debug == 2;
html_header("$node setup", 1);
print "<body><center>\n";
alert_banner();
print "<form method=post action=/cgi-bin/ports.pl enctype='multipart/form-data'>\n" unless $debug == 2;
print "<form method=post action=test>\n" if $debug == 2;

print "<table width=790>\n";
print "<tr><td>\n";
navbar("ports");
print "</td></tr>\n";

#
# control buttons
#

print "<tr><td align=center>
<a href='/help.html#ports' target='_blank'>Help</a>
&nbsp;&nbsp;&nbsp;
<input type=submit name=button_save value='Save Changes' title='Save and use these settings now (takes about 20 seconds)'>&nbsp;
<input type=submit name=button_reset value='Reset Values' title='Revert to the last saved settings'>&nbsp;
<input type=submit name=button_refresh value='Refresh' title='Refresh this page'>&nbsp\n";
print "<tr><td>&nbsp;</td></tr>\n";
push @hidden, "<input type=hidden name=reload value=1></td></tr>";

#
# messages
#

if($parms{button_save})
{
    if(@port_err or @dhcp_err or @dmz_err or @serv_err)
    {
	print "<tr><td align=center><b>Configuration NOT saved!</b></td></tr>\n";
    }
    elsif(@errors)
    {
	print "<tr><td align=center><b>Configuration saved, however:<br>";
	foreach(@errors) { print "$_<br>" }
	print "</b></td></tr>\n";
    }
    else
    {
	print "<tr><td align=center><b>Configuration saved and is now active.</b></td></tr>\n";
    }

    print "<tr><td>&nbsp;</td></tr>\n";
}

#
# everything else
#

if($dmz_mode)
{
    print "<tr><td align=center><table width=100%>\n";
    print "<tr><td width=1 align=center valign=top>\n";
    &print_reservations();
    print "</td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td><td align=center valign=top>\n";
    &print_services();
    print "</td>\n";
    print "</tr></table></td></tr>\n";
    print "<tr><td>&nbsp;</td></tr>\n";
    print "<tr><td><hr></td></tr>\n";  
    print "</table><table width=790>\n";
    print "<tr><td align=center valign=top>\n";
    &print_forwarding();
    print "</td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td>\n";
    print "<td align=center valign=top>\n";
    &print_aliases();
    print "</td></tr>\n";
}
else
{
    print "<tr><td align=center><table width=100%>\n";
    print "<tr><td width=1 align=center valign=top>\n";
    &print_forwarding();
    print "</td>\n";

    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td><td align=center valign=top>\n";
    &print_services();
    print "</td>\n";

    print "</tr></table></td></tr>\n";
    print "<tr><td>&nbsp;</td></tr>\n";
    print "<tr><td><hr></td></tr>\n";
    print "</table><table width=790>\n";
    print "<tr><td align=center>\n";
    &print_reservations();
    print "</td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td>\n";
    print "<td align=center valign=top>\n";
    &print_aliases();
    print "</td></tr>\n";
}

print "</table>\n";

push @hidden, "<input type=hidden name=port_num value=$parms{port_num}>";
push @hidden, "<input type=hidden name=dhcp_num value=$parms{dhcp_num}>";
push @hidden, "<input type=hidden name=serv_num value=$parms{serv_num}>";
push @hidden, "<input type=hidden name=alias_num value=$parms{alias_num}>";
foreach(@hidden) { print "$_\n" }

print "</form></center>\n";
show_debug_info();
page_footer();
print "</body></html>\n";
exit;


#
# page subsections
#

sub print_forwarding
{
    print "<table cellpadding=0 cellspacing=0><tr><th colspan=7>Port Forwarding</th></tr>\n";
    print "<tr><td>&nbsp;</td><td align=center>Interface</td><td align=center>Type</td>";
    print "<td align=center>Outside<br>Port</td><td align=center>LAN IP</td>";
    print "<td align=center width=1>LAN<br>Port</td><td>&nbsp;</td></tr>\n";

    for($i = 1, @list = (); $i <= $parms{port_num}; ++$i) { push @list, $i }
    push @list, "_add";

    foreach $val (@list)
    {
	foreach $var (qw(intf type out ip in enable adv link proto suffix name))
	{
	    eval sprintf("\$%s = \$parms{port%s_%s}", $var, $val, $var);
	}

	print "<tr><td colspan=7 height=10></td></tr>\n" if $val eq "_add" and scalar(@list) > 1;

	# enable checkbox
	if(0)#$val ne "_add")
	{
	    print "<tr><td", $dmz_mode ? ">" : " rowspan=2>";
	    print "<nobr>enable<input type=checkbox name=port${val}_enable value=1 ";
	    if($enable) { print "title='deactivate this rule but keep the settings' checked" }
	    else        { print "title='activate this rule'" }
	    print ">&nbsp;&nbsp;</td>";
	}
	else
	{
	    print "<tr><td>&nbsp;</td>";
	    push @hidden, "<input type=hidden name=port${val}_enable value=1>";
	}

	# port forwarding settings
	print "<td align=center valign=top><select name=port${val}_intf title='forward inbound packets from this interface'>\n";
	unless ($dmz_mode)
	{
	    selopt("WiFi", "wifi", $intf);
	    selopt("WAN",  "wan",  $intf);
	    selopt("Both", "both", $intf);
	}
	else
	{
	    selopt("WAN",  "wan",  $intf);
	}
	print "</select></td>";

	print "<td align=center valign=top><select name=port${val}_type>\n";
	selopt("TCP", "tcp", $type);
	selopt("UDP", "udp", $type);
	selopt("Both", "both", $type);
	print "</select></td>";

	print "<td align=center valign=top><input type=text name=port${val}_out value='$out' size=8></td>\n";

	print "<td align=center valign=top><select name=port${val}_ip>\n";
	print "<option value=''>- IP Address -</option>\n" if $val eq "_add";
	for($i = 1; $i < (1 << (32 - $lancidr)) - 1; $i++)
	{
	    $selip = add_ip_address($lannet, $i);
	    $ipname = $dhcphosts{$selip};
	    $ipname = $selip unless $ipname;
	    #next if $selip eq $lanip;
	    selopt($ipname, $selip, $ip);
	}
	print "</select></td>\n";

	print "<td align=left valign=top><input type=text name=port${val}_in value='$in' size=4></td>\n";
	print "<td><nobr>&nbsp;<input type=submit name=";

	if($val eq "_add") { print "port_add value=Add title='Add this as a port forwarding rule'" }
	else               { print "port${val}_del value=Del title='Remove this rule'" }

	print "></nobr></td></tr>\n";

	# display any errors
	while(@port_err and $port_err[0] =~ /^$val /)
	{
	    $err = shift @port_err;
	    $err =~ s/^\S+ //;
	    print "<tr><th colspan=7>$err</th></tr>\n";
	}

	print "<tr><td colspan=7 height=5></td></tr>\n";
    }

    # dmz server for nat mode
    unless($dmz_mode)
    {
	print "<tr><td colspan=7 height=10></td></tr>\n";
	print "<tr><td colspan=4 align=right>DMZ Server &nbsp; </td>";
	print "<td colspan=3><select name=dmz_ip onChange='form.submit()' ";
	print "title='Send all other inbound traffic to this host'>\n";
	print "<option value=''>None</option>\n";
	for($i = 1; $i < (1 << (32 - $lancidr)) - 1; $i++)
	{
	    $selip = add_ip_address($lannet, $i);
	    next if $selip eq $lanip;
	    $ipname = $dhcphosts{$selip};
	    $ipname = $selip unless $ipname;
	    selopt($ipname, $selip, $parms{dmz_ip});
	}
	print "</select></td>\n";

	foreach(@dmz_err) { print "<tr><th colspan=8>$_</th></tr>\n" }
    }

    print "</table>\n";
}


sub print_reservations
{
    print "<table cellpadding=0 cellspacing=0><tr><th colspan=4>DHCP Address Reservations</th></tr>\n";
    print "<tr><td colspan=4 height=5></td></tr>\n";
    print "<tr><td align=center>Hostname</td><td align=center>IP Address</td><td align=center>MAC Address</td>";
    if($dmz_mode) {
      print "<td align=center style='font-size:10px;'>Do Not<br>Propagate</td><td></td></tr>\n";
    } else { print "<td></td><td></td></tr>\n"; }
    print "<tr><td colspan=4 height=5></td></tr>\n";

    for($i = 1, @list = (); $i <= $parms{dhcp_num}; ++$i) { push @list, $i }
    push @list, "_add";

    foreach $val (@list)
    {

	$host = $parms{"dhcp${val}_host"};
	$ip   = $parms{"dhcp${val}_ip"};
	$mac  = lc $parms{"dhcp${val}_mac"};
        $noprop = $parms{"dhcp${val}_noprop"};

	print "<tr><td colspan=4 height=10></td></tr>\n" if $val eq "_add" and scalar(@list) > 1;
	print "<tr><td><input type=text name=dhcp${val}_host value='$host' size=10></td>\n";

	print "<td align=center><select name=dhcp${val}_ip>\n";
	print "<option value=''>- IP Address -</option>\n" if $val eq "_add";
	for($i = $dhcp_start; $i <= $dhcp_end; $i++)
	{
	    $selip = add_ip_address($lannet, $i - ($lannet_d & 0xff));
	    next if $selip eq $lanip;
	    $ipname = $dhcphosts{$selip};
	    $ipname = $selip if $selip eq $ip or not $ipname;
	    selopt($ipname, $selip, $ip);
	}
	print "</select></td>\n";

	print "<td><input type=text name=dhcp${val}_mac value='$mac' size=16></td>\n";
    if($dmz_mode) {
      if ($noprop eq "#NOPROP") {
        print "<td align=center><input type=checkbox id=dhcp${val}_noprop name=dhcp${val}_noprop value='#NOPROP' checked></td>\n";
      }else {
        print "<td align=center><input type=checkbox id=dhcp${val}_noprop name=dhcp${val}_noprop value='#NOPROP'></td>\n";
      }
    }else { print "<td></td>\n"; }
    
	print "<td><nobr>&nbsp;<input type=submit name=";

	if($val eq "_add") { print "dhcp_add       value=Add title='Add this as a DHCP reservation'" }
	else               { print "dhcp${val}_del value=Del title='Remove this reservation'" }

	print "></nobr></td></tr>\n";

	# display any errors
	while(@dhcp_err and $dhcp_err[0] =~ /^$val /)
	{
	    $err = shift @dhcp_err;
	    $err =~ s/^\S+ //;
	    print "<tr><th colspan=4>$err</th></tr>\n";
	}

	print "<tr><td height=5></td></tr>\n";
    }

    print "<tr><td>&nbsp;</td></tr>\n";
    print "<tr><th colspan=4>Current DHCP Leases</th></tr>\n<tr>";
    $i = 0;
    foreach(`cat /tmp/dhcp.leases 2>/dev/null`)
    {
	++$i;
	($junk, $mac, $ip, $host) = split /\s+/, $_;
	print "<tr><td height=5></td></tr>\n";
	print "<tr><td align=center>$host</td><td align=center><small>$ip</small></td>";
	print "<td align=center><small>$mac</small></td><td></td><td><nobr>&nbsp;";
	print "<input type=submit name=lease${i}_add  value=Add ";
	print "title='Use these values as an address reservation'></nobr></td></tr>\n";
	push @hidden, "<input type=hidden name=lease${i}_host value=$host>";
	push @hidden, "<input type=hidden name=lease${i}_ip   value=$ip>";
	push @hidden, "<input type=hidden name=lease${i}_mac  value=$mac>";
    }

    print "<tr><td align=center colspan=4>there are no active leases</td></tr>\n" unless $i;
    print "</table>\n";
}


sub print_services
{
    print "<table cellpadding=0 cellspacing=0><tr><th colspan=4>Advertised Services</th></tr>\n";

    unless($dmz_mode or $parms{port_num} or $parms{dmz_ip})
    {
	if($dmz_mode) { print "<tr><td>&nbsp;</td></tr><tr><td height=10></td></tr>\n" }
	else          { print "<tr><td>&nbsp;<br><br>", "</td></tr>\n" }
	print "<tr><td colspan=4 align=center>none</td></tr>\n";
	print "</table>\n";
	return;
    }

    print "<tr><td height=5></td></tr>\n" if $dmz_mode;
    print "<tr><td>Name</td><td>Link</td><td>URL</td><td>", $dmz_mode ? "" : "<br><br>", "</td></tr>\n";
    print "<tr><td height=5></td></tr>\n" if $dmz_mode;

    for($i = 1, @list = (); $i <= $parms{serv_num}; ++$i) { push @list, $i }
    push @list, "_add";

    foreach $val (@list)
    {
	foreach $var (qw(name link proto host port suffix))
	{
	    eval sprintf("\$%s = \$parms{serv%s_%s}", $var, $val, $var);
	}

	unless($dmz_mode) { $parms{"serv${val}_host"} = $host = $node }
	#unless($link) { $proto = $port = $suffix = "" }

	print "<tr><td colspan=4 height=10></td></tr>\n" if $val eq "_add" and scalar(@list) > 1;
	print "<tr>";
	print "<td><input type=text size=6 name=serv${val}_name value='$name' title='what to call this service'></td>";

	print "<td><nobr><input type=checkbox name=serv${val}_link value=1";
	print " onChange='form.submit()'" unless $val eq "_add";
	print " checked" if $link;
	print " title='create a clickable link for this service'>";
	print "<input type=text size=2 name=serv${val}_proto value='$proto' title='URL Protocol'";
	print " disabled" unless $val eq "_add" or $link;
	print "></nobr></td>";

	if($dmz_mode)
	{
	    print "<td><nobr><b>:</b>//<select name=serv${val}_host";
	    print " disabled" unless $val eq "_add" or $link;
	    print ">\n";
	    selopt($node, $node, $host);
	    for($i = 1; $i <= $parms{alias_num}; $i++) {
            selopt($parms{"alias${i}_host"}, $parms{"alias${i}_host"}, $host);
	    }
	    for($i = 1; $i <= $parms{dhcp_num}; $i++)
	    {
		selopt($parms{"dhcp${i}_host"}, $parms{"dhcp${i}_host"}, $host);
	    }
	    print "</select>\n";
	}
	else
	{
	    print "<td><nobr><b>:</b>//<small>$host</small>";
	}

	print "<b>:</b><input type=text size=2 name=serv${val}_port value='$port' title='port number'";
	print " disabled" unless $val eq "_add" or $link;
	print "> / <input type=text size=6 name=serv${val}_suffix value='$suffix' ";
	print "title='leave blank unless the URL needs a more specific path'";
	print " disabled" unless $val eq "_add" or $link;
	print "></nobr></td>";

	print "<td><nobr>&nbsp;<input type=submit name=";
	if($val eq "_add") { print "serv_add       value=Add title='Add this as a service'" }
	else               { print "serv${val}_del value=Del title='Remove this service'" }
	print "></nobr></td></tr>\n";

	# display any errors
	while(@serv_err and $serv_err[0] =~ /^$val /)
	{
	    $err = shift @serv_err;
	    $err =~ s/^\S+ //;
	    print "<tr><th colspan=4>$err</th></tr>\n";
	}

	unless($link or $val eq "_add")
	{
	    push @hidden, "<input type=hidden name=serv${val}_proto  value='$proto'>";
	    push @hidden, "<input type=hidden name=serv${val}_host   value='$host'>";
	    push @hidden, "<input type=hidden name=serv${val}_port   value='$port'>";
	    push @hidden, "<input type=hidden name=serv${val}_suffix value='$suffix'>";
	}

	print "<tr><td colspan=4 height=4></td></tr>\n";
    }

    print "</table>\n";
}

# aliases
sub print_aliases {
  print "<table cellpadding=0 cellspacing=0><tr><th colspan=4>DNS Aliases</th></tr>\n";
  print "<tr><td colspan=3 height=5></td></tr>\n";
  print "<tr><td align=center>Alias Name</td><td></td><td align=center>IP Address</td></tr>\n";
  print "<tr><td colspan=3 height=5></td></tr>\n";
  for($i = 1, @list = (); $i <= $parms{alias_num}; ++$i) { push @list, $i }
  push @list, "_add";
  foreach $val (@list) {
    $host = $parms{"alias${val}_host"};
    $ip = $parms{"alias${val}_ip"};
    print "<tr><td colspan=3 height=10></td></tr>\n" if $val eq "_add" and scalar(@list) > 1;
    print "<tr><td align=center><input type=text name=alias${val}_host value='$host' size=20></td>\n";
    print "<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td>";
    print "<td align=center><select name=alias${val}_ip>\n";
    print "<option value=''>- IP Address -</option>\n" if $val eq "_add";
    for($i = $dhcp_start; $i <= $dhcp_end; $i++) {
        $selip = add_ip_address($lannet, $i - ($lannet_d & 0xff));
        next if $selip eq $lanip;
        if(defined($dhcphosts{$selip})) {
            $ipname = $dhcphosts{$selip};
            selopt($ipname, $selip, $ip);
        }else {
            $ipname = $selip or $ip;
            selopt($ipname, $selip, $ip);
        }
    }
    print "</select></td>\n";
    print "<td><nobr>&nbsp;<input type=submit name=";
    if($val eq "_add") { print "alias_add       value=Add title='Add Alias'" }
    else               { print "alias${val}_del value=Del title='Remove Alias'" }
	print "></nobr></td></tr>\n";
  }
  while(@alias_err)
	{
	    $err = shift @alias_err;
	    $err =~ s/^\S+ //;
	    print "<tr><th colspan=4>$err</th></tr>\n";
	}
  print "</table>\n";
}
