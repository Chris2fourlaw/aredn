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

%rateL = (
	'1.0M' => '1',   # CCP LP
	'2.0M' => '2',   # CCP LP
	'5.5M' => '5.5', # CCP LP
	'MCS0' => '6.5', # HT20 LGI
	'11.0M'=> '11',  # CCP LP
	'MCS1' => '13',  # HT20 LGI...
	'MCS2' => '19.5',
	'MCS3' => '26',
	'MCS4' => '39',
	'MCS5' => '52',
	'MCS6' => '58.5',
	'MCS7' => '65',
	'MCS8' => '13',
	'MCS9' => '26',
	'MCS10' => '39',
	'MCS11' => '52',
	'MCS12' => '78',
	'MCS13' => '104',
	'MCS14' => '117',
	'MCS15' => '130',
);

%rateS = (
	'MCS0' => '7.2',
	'MCS1' => '14.4',
	'MCS2' => '21.7',
	'MCS3' => '28.9',
	'MCS4' => '43.3',
	'MCS5' => '57.8',
	'MCS6' => '65',
	'MCS7' => '72.2',
	'MCS8' => '14.4',
	'MCS9' => '28.9',
	'MCS10' => '43.3',
	'MCS11' => '57.8',
	'MCS12' => '86.7',
	'MCS13' => '115.6',
	'MCS14' => '130',
	'MCS15' => '144.4',
	);

# Limit displayed nodes and services to the most reachable routes if memory on the node is small
%lowMemoryLimits = (
        memory => `/sbin/uci -q get aredn.\@meshstatus[0].lowmem` || 10000,
        routes => `/sbin/uci -q get aredn.\@meshstatus[0].lowroutes` || 1000,
);

sub get_available_mem
{
  foreach(`free`)
  {
    next unless /^Mem[:]/;
    my @tmp = split /\s+/, $_;
    return $tmp[6];
  }
  return "N/A";
}

# collect some variables
$node = nvram_get("node");
$node = "NOCALL" if $node eq "";
$tactical = nvram_get("tactical");
$config = nvram_get("config");
$config = "not set" if $config eq "" || not -d "/etc/config.mesh";
($my_ip) = get_ip4_network(get_interface("wifi"));
${wifiif} = `uci -q get 'network.wifi.ifname'`;
chomp ${wifiif};
$phy = get_wlan2phy("${wifiif}");

chomp ($chanbw = `cat /sys/kernel/debug/ieee80211/${phy}/ath9k/chanbw`);
if    ($chanbw eq "0x00000005") {$chanbw = 4;}
elsif ($chanbw eq "0x0000000a") {$chanbw = 2;}
  else   			{$chanbw = 1;}

read_postdata();

system "mkdir -p /tmp/web";
system "touch /tmp/web/automesh" if $parms{auto};
system "rm -f /tmp/web/automesh" if $parms{stop};

#get location info if available
$lat=&uci_get_indexed_option("aredn","location",0,"lat");
$lon=&uci_get_indexed_option("aredn","location",0,"lon");
if($lat ne "" and $lon ne "")
{
    $lat_lon = "<center><strong>Location: </strong> $lat $lon</center>";
}
else
{
    $lat_lon = "<strong>Location Not Available</strong>";
}
@route30 = `/sbin/ip route list table 30`;
$olsrTotal = scalar @route30;
$olsrNodes = scalar grep /\//, @route30;
$node_desc = `/sbin/uci -q get system.\@system[0].description`; #pull the node description from uci
undef @route30;

# parse the txtinfo output

chomp($tmperr = `mktemp /tmp/web/nc.XXXXXX`);

foreach(`echo /rou | nc 127.0.0.1 2006 2>>$tmperr`)
{
    next if /^\D/;
    my ($ip, $junk, $junk, $etx) = split /\s+/, $_;
    my ($net, $cidr) = split /\//, $ip;
    if ( $etx <= 50 ) { $routes{$net}{etx} = $etx; }
}
if ($olsrTotal > $lowMemoryLimits{routes} && get_available_mem() < $lowMemoryLimits{memory})
{
    my @oroutes = sort { $routes{$a}{etx} <=> $routes{$b}{etx} } keys %routes;
    foreach ( @oroutes[$lowMemoryLimits{routes} .. $#oroutes] )
    {
      delete $routes{$_};
    }
}
@arps = {};
open my $fh, '<', '/proc/net/arp';
foreach (<$fh>) { push @arps, $_ if (/$wifiif/ && !/00:00:00:00:00:00/) }
close $fh;
foreach(`echo /lin | nc 127.0.0.1 2006 2>>$tmperr`)
{
    next if /^\D/;
    my ($junk, $ip, $junk, $lq, $nlq) = split /\s+/, $_;
    $links{$ip} = {
        lq => $lq,
        nlq => $nlq,
        mbps => ""
    };
    $neighbor{$ip} = 1;

    my ($mac) = grep /^$ip/, @arps;
    $mac =~ s/^.*(\w\w:\w\w:\w\w:\w\w:\w\w:\w\w).*$/$1/;
    chomp $mac;

    open my $fh, '<', "/sys/kernel/debug/ieee80211/${phy}/netdev:${wifiif}/stations/$mac/rc_stats_csv";
    if ( $mac && $fh )
    {
        my @csv = <$fh>;
        close $fh;
        #802.11b/n
        my ($mbps) = grep /^([^,]*,){3}A/, @csv;
        if ($mbps)
        {
            my ($gi, $dummy, $rate, $dummy, $ewma) = $mbps =~ /^[^,]*,([^,]*),([^,]*,){2}([^,]*),([^,]*,){4}([^,]*).*$/ ;
            $rate =~ s/[ \t]//g;
            $mbps =  $gi eq "SGI" ?  $rateS{$rate}*$ewma/100 : $rateL{$rate}*$ewma/100 ;
        }
        else
        {
            #802.11a/b/g
            ($mbps) = grep /^A/, @csv;
            if ($mbps)
            {
            $mbps =~ /^[^,]*,([^,]*),([^,]*,){4}([^,]*).*$/;
            $mbps = $1*$3/100;
            }
        }
        $links{$ip}{mbps} = $mbps ? sprintf "%.1f", $mbps / $chanbw : "0.0";
    }
}
undef @arps;
foreach(`echo /hna | nc 127.0.0.1 2006 2>>$tmperr`)
{
    next if /^\D/;
    my ($iproute, $ip) = split /\s+/, $_;
    my ($net, $cidr) = split /\//, $iproute;
    if ( $net eq "0.0.0.0" ) {  $wangateway{$ip} = 1; }
}
foreach(`echo /mid | nc 127.0.0.1 2006 2>>$tmperr`)
{
    next if /^\D/;
    my ($ip, $junk) = $_ =~ /^(\S+)\s+(.*)$/;
    foreach $aip ( split /\s+/, $junk )
    {
        $ipalias{$aip} = $ip;
        $neighbor{$aip} = 1;
        if ( $links{$aip} ) { $neighbor{$ip} = 1 }
    }
}

# stat and -s do not work in microperl
@parts = split /\s+/, `ls -l $tmperr`;
$txtinfo_err = $parts[4];
unlink $tmperr;

# load the local hosts file

open my $fh, '<', '/etc/hosts';
foreach (<$fh>)
{
    next unless /^10[.]/;
    chomp;
    my ($ip, $name, $tactical) = split /\s+/, $_;
    next if $name =~ /^(localhost|localnode|localap|dtdlink\..*)$/;
    if ( $name !~ /\./ ) { $name="${name}.local.mesh"; }
    if($ip eq $my_ip)
    {
	$tactical = "" unless $tactical;
	$localhosts{$ip}{tactical} = $tactical;
	$localhosts{$ip}{name} = $name;
    }
    else { push @{$localhosts{$my_ip}{hosts}}, $name; }
    if($tactical eq "#NOPROP") { push @{$localhosts{$my_ip}{noprops}}, $name; }
    if($tactical eq "#ALIAS") { push @{$localhosts{$my_ip}{aliases}}, $name; }
}
close $fh;

# load the olsr hosts file
open my $fh, '<', '/var/run/hosts_olsr';
foreach (<$fh>)
{
    next unless /^\d/;
    chomp;
    my ($ip, $name, undef, $originator, undef, undef) = split /\s+/, $_;
    next unless $originator;
    next if $originator eq "myself";
    # Filter hosts which are unreachable
    next unless $routes{$ip} || $routes{$originator};

    my $etx = $routes{$ip}{etx} ? $routes{$ip}{etx} : $routes{$originator}{etx};

    if (( $name !~ /\./ ) || ( $name =~ /^mid\.[^\.]*$/ )) { $name="${name}.local.mesh"; }

    if ( $ip eq $originator )
    {
        if ($hosts{$ip}{name})
        {
            $hosts{$ip}{tactical} = $name;
        }
        else
        {
            $hosts{$ip}{name} = $name;
            $hosts{$ip}{etx} = $etx;
        }
    }
    elsif ( $name =~ /^dtdlink\..*$/ )
    {
        $dtd{$originator} = 1;
        if ( $links{$ip} ) { $links{$ip}{dtd} = 1 }
    }
    elsif ( $name =~ /^mid\d+\..*$/  )
    {
        $midcount{$originator} = $midcount{$originator} ? $midcount{$originator}+1: 1 ;
        if ( $links{$ip} ) { $links{$ip}{tun} = 1 }
    }
    else
    {
        push @{$hosts{$originator}{hosts}}, $name;
    }
}
close $fh;

# Discard
undef %routes;

# load the olsr services file
open my $fh, '<', '/var/run/services_olsr';
foreach (<$fh>)
{
    next unless /^\w/;
    chomp;
    my ($url, $junk, $name) = split /\|/, $_;
    next unless defined $name;
    my ($protocol, $host, $port, $path) = $url =~ /^(\w+):\/\/([\w\-\.]+):(\d+)\/(.*)/;
    next unless defined $path;
    my ($name, $originator) = split /\#/, $name;

    # Filter services for unreachable hosts
    next unless $hosts{$originator}{name} || $originator eq " my own service";

    $name =~ s/\s+$//;

    if ( $host !~ /\./ ) { $host="${host}.local.mesh"; }

    # attempt to work around olsr never forgetting defunct services
    # assume that the first entry in the file by this name is the most recent, ignore the rest
    next if $services{$host}{$name};

    $services{$host}{$name} = $port ? "<a href='${protocol}://${host}:${port}/${path}' target='_blank'>$name</a>" : $name;
}
close $fh;

# load the node history
open my $fh, '<', '/tmp/node.history';
foreach (<$fh>)
{
    chomp;
    ($ip, $age, $host) = split / /, $_;
    next unless $age;
    $host = "" unless $host;
    $host =~ s|/| / |;
    $history{$ip}{age} = $age;
    $history{$ip}{host} = $host;
}
close $fh;

#delete $hosts{"127.0.0.1"};

# compress the output if we can                                                                                            
if ( $ENV{HTTP_ACCEPT_ENCODING} =~ /gzip/ )                                                                                
{                                                                                                                          
    print "Content-type: text/html\r\nCache-Control: no-store\r\nContent-Encoding: gzip\r\n\r\n";                      
    open my $zout, "|gzip";                                                                                            
    select $zout;                                                                                                      
}                                                                                                                          
else                                                                                                                       
{                                                                                                                          
    print "Content-type: text/html\r\nCache-Control: no-store\r\n\r\n";                                                
}    

# generate the page
html_header("$node mesh status", 0);
print "<meta http-equiv='refresh' content='10;url=/cgi-bin/mesh'>\n" if -f "/tmp/web/automesh";
print "</head>\n";
print "<body><form method=post action=/cgi-bin/mesh enctype='multipart/form-data'>\n";
print "<input type=hidden name=reload value=1>\n";
print "<center>\n";

alert_banner();

# page header
print "<h1>$node mesh status</h1>";

print "$lat_lon"; #display lat lon info
print "<table id='node_description_display'><tr><td>$node_desc</td></tr></table>" if $node_desc; #display node description
print "<hr><nobr>";

# nav buttons
if(-f "/tmp/web/automesh")
{
    print "<input type=submit name=stop value=Stop title='Abort continuous status'>\n";
}
else
{
    print "<input type=submit name=refresh value=Refresh title='Refresh this page'>\n";
    print "&nbsp;&nbsp;&nbsp;\n";
    print "<input type=submit name=auto value=Auto title='Automatic page refresh'>\n";
}

print "&nbsp;&nbsp;&nbsp";
print "<button type=button onClick='window.location=\"status\"' title='Return to the status page'>Quit</button>\n";

if($txtinfo_err)
{
    print "<br><br><b>Whoops! OLSR is not running, try again later.</b>\n";
    print "</center></form>";
    page_footer();
    print "</body></html>\n";
    exit;
}

print "</nobr><br><br>\n";

unless(keys %localhosts || keys %links)
{
    print "No other nodes are available.\n";
    print "</center></form>";
    page_footer();
    print "</body></html\n";
    exit;
}


print "<table><tr><td valign=top><table>\n";


# show local hosts

print "<tr><th colspan=4 align=left><nobr>Local Hosts</nobr></th><th align=left>Services</th></tr>\n";
print "<tr><td colspan=5><hr></td></tr>\n";

if(keys %localhosts)
{
    my %rows = ();

    foreach $ip (keys %localhosts)
    {
	my $host = $localhosts{$ip}{name};
        my $localpart = $host =~ s/.local.mesh//r;
	my $tactical = $localhosts{$ip}{tactical} ? " / " . $localhosts{$ip}{tactical} : "";
	$rows{$host} = sprintf "<tr><td valign=top><nobr>%s</nobr>", $localpart . $tactical;

        if ( $wangateway{$ip} ) { $nodeiface =  "wan" ; }
	if ( $nodeiface ) { $rows{$host} .= " &nbsp; <small>($nodeiface)</small>"; }

	$rows{$host} .= "</td><td colspan=3>&nbsp;</td><td>\n" ;

	foreach(sort keys %{$services{$host}})
	{
	    $rows{$host} .= "<nobr>" . $services{$host}{$_} . "</nobr><br>\n";
	}
	$rows{$host} .= "</td></tr>\n";

	# add locally advertised dmz hosts
	foreach $dmzhost (@{$localhosts{$ip}{hosts}})
	{
        #find non-propagated and aliased hosts and change color
        my $nopropd = 0;
	my $aliased = 0;
        if(grep { /$dmzhost/ } @{$localhosts{$ip}{noprops}}) { $nopropd = 1; }
	if(grep { /$dmzhost/ } @{$localhosts{$ip}{aliases}}) { $aliased = 1; }
        $localpart = $dmzhost =~ s/.local.mesh//r;
	    if(!$nopropd && !$aliased) { $rows{$host} .= "<tr><td valign=top><nobr>&nbsp;<img src='/dot.png'>$localpart</nobr></td>"; }
	    elsif($aliased) { $rows{$host} .= "<tr><td class=aliased-hosts valign=top title='Aliased Host'><nobr>&nbsp;<img src='/dot.png'>$localpart</nobr></td>"; }
	    else { $rows{$host} .= "<tr><td class=hidden-hosts valign=top title='Non Propagated Host'><nobr>&nbsp;<img src='/dot.png'>$localpart</nobr></td>"; }
	    $rows{$host} .= "<td colspan=3></td><td>\n";
	    foreach(sort keys %{$services{$dmzhost}})
	    {
		$rows{$host} .= "<nobr>" . $services{$dmzhost}{$_} . "</nobr><br>\n";
	    }
	    $rows{$host} .= "</td></tr>\n";
	}
    }

    foreach(sort keys %rows) { print $rows{$_} }
}
else
{
    print "<tr><td>none</td></tr>\n";
}


# show remote nodes

print "<tr><td>&nbsp;</td></tr>\n";
print "<tr><th align=left><nobr>Remote Nodes</nobr></th><th>&nbsp;&nbsp;</th><th>ETX</th><th>&nbsp;&nbsp;</th><th align=left>Services</th></tr>\n";
print "<tr><td colspan=5><hr></td></tr>\n";

my $row;
foreach $ip (sort { $hosts{$a}{etx} <=> $hosts{$b}{etx} } keys %hosts)
{
    next if $neighbor{$ip};
    my $host = $hosts{$ip}{name};
    next unless $host;
    my $localpart = $host =~ s/.local.mesh//r;
    my $tactical = $hosts{$ip}{tactical} ? " / " . $hosts{$ip}{tactical} : "";
    my $etx = sprintf "%.2f", $hosts{$ip}{etx};

    $row  = sprintf "<tr><td valign=top><nobr><a href='http://%s:8080/'>%s</a>", $host, $localpart . $tactical;

    my $nodeiface;
    my $mcount = 0 + $midcount{$ip};
    if ( $dtd{$ip} ) { $mcount -= 1; } # extra mid entry matching and with dtdlink in hosts_olsrd
    if ( $hosts{$ip}{tactical} ) { $mcount -= 1; } # extra mid entry if tactical name defined
    if ( $mcount > 0 ) { $nodeiface = "tun*$mcount" ;  }
    if ( $wangateway{$ip} ) { $nodeiface = $nodeiface ? $nodeiface . ",wan" : "wan" ; }

    if ( $nodeiface ) { $row .= " &nbsp; <small>($nodeiface)</small>"; }

    $row .= sprintf "</nobr></td><td></td><td align=right valign=top>%s</td><td></td><td>\n", $etx;
    foreach(sort keys %{$services{$host}})
    {
	$row .= "<nobr>" . $services{$host}{$_} . "</nobr><br>\n";
    }
    $row .= "</td></tr>\n";

    # add advertised dmz hosts
    foreach $dmzhost (@{$hosts{$ip}{hosts}})
    {
        my $localpart = $dmzhost =~ s/.local.mesh//r;
	$row .= "<tr><td valign=top><nobr>&nbsp;<img src='/dot.png'>$localpart</nobr></td>";
	$row .= "<td colspan=3></td><td>\n";
	foreach(sort keys %{$services{$dmzhost}})
	{
	    $row .= "<nobr>" . $services{$dmzhost}{$_} . "</nobr><br>\n";
	}
	$row .= "</td></tr>\n";
    }
    print $row;
}

undef %neighbor;

if(!$row)
{
    print "<tr><td>none</td></tr>\n";
}


print "</table></td><td width=20>&nbsp;</td><td valign=top><table>\n";

# show current neighbors

print "<tr><th align=left><nobr>Current Neighbors</nobr></th><th>&nbsp;&nbsp;</th><th>LQ</th><th>NLQ</th><th>TxMbps</th><th>&nbsp;&nbsp;</th><th align=left>Services</th></tr>\n";
print "<tr><td colspan=7><hr></td></tr>\n";

if(keys %links)
{
    my %rows = ();

    foreach $ip (keys %links)
    {
	my $ipmain = exists $ipalias{$ip} ? $ipalias{$ip} : $ip ;
	my $host = $hosts{$ipmain}{name} ? $hosts{$ipmain}{name} : $ipmain;
        my $localpart = $host =~ s/.local.mesh//r;
	my $tactical = $hosts{$ipmain}{tactical} ? " / " . $hosts{$ipmain}{tactical} : "";
        if ( $rows{$host} ) { $host .= " " ; } # avoid collision 2 links to same host {rf, dtd}

	my $no_space_host=$host;
	$no_space_host =~ s/\s+$//;
	my $row = sprintf "<tr><td valign=top><nobr><a href='http://%s:8080/'>%s</a>", $no_space_host, $localpart . $tactical;

	my $nodeiface;
	if ( $ipmain ne $ip ) # indicate if dtd or tunnel interface to neighbor
	{
            if    ( $links{$ip}{dtd} ){ $nodeiface="dtd" ; }
	    elsif ( $links{$ip}{tun} ){ $nodeiface="tun" ; }
            else { $nodeiface="?" ; }
	}

	if ( $wangateway{$ip} || $wangateway{$ipmain} ) { $nodeiface = $nodeiface ? $nodeiface . ",wan" :  "wan" ; }
        if ( $nodeiface ) { $row .= " &nbsp; <small>($nodeiface)</small>"; }

        $row .= sprintf ("</nobr></td><td></td><td align=right valign=top>%.0f%%</td><td align=right valign=top>%.0f%%</td><td align=right valign=top>%s</td><td></td><td>\n", 100*$links{$ip}{lq}, 100*$links{$ip}{nlq},$links{$ip}{mbps});

	if ( ! exists $neighservices{$host} )
	    {
	    foreach(sort keys %{$services{$host}}) { $row .= "<nobr>" . $services{$host}{$_} . "</nobr><br>\n" }

	    $row .= "</td></tr>\n";

	    # add advertised dmz hosts
	    foreach $dmzhost (@{$hosts{$ipmain}{hosts}})
	    {
                my $localpart = $dmzhost =~ s/.local.mesh//r;
	        $row .= "<tr><td valign=top><nobr>&nbsp;<img src='/dot.png'>$localpart</nobr></td><td colspan=5></td><td>\n";
	        foreach(sort keys %{$services{$dmzhost}}) { $row .= $services{$dmzhost}{$_} . "<br>\n" }
	        $row .= "</td></tr>\n";
	    }
	    $neighservices{$host}=1;
	}

	$rows{$host}=$row;
    }

    foreach(sort keys %rows) { print $rows{$_} }
}
else
{
    print "<tr><td>none</td></tr>\n";
}

undef %services;

# show previous neighbors

print "<tr><td>&nbsp;</td></tr>\n";
print "<tr><th colspan=6 align=left><nobr>Previous Neighbors</nobr></th><th align=left>When</th></tr>\n";
print "<tr><td colspan=7><hr></td></tr>\n";
%rows = ();
($uptime) = `cat /proc/uptime` =~ /^(\d+)/;

foreach $ip (keys %history)
{
    next if $links{$ip};
    next if $links{$ipalias{$ip}};
    $age = sprintf "%010d", $uptime - $history{$ip}{age};
    $host = $history{$ip}{host} ? $history{$ip}{host} : $ip;
    $host =~ s/^mid\d+\.// ;
    $host =~ s/^dtdlink\.// ;
    $rows{$age} .= sprintf "<tr><td colspan=6><nobr>%s</nobr>", $host;
    foreach(@{$hosts{$ip}{hosts}}) { $rows{$age} .= "<br><nobr><img src='/dot.png'>$_</nobr>" }
    $rows{$age} .= "</td><td valign=top><nobr>";
    if($age < 3600)
    {
	$val = int($age/60);
	$rows{$age} .= $val == 1 ? "1 minute ago" : "$val minutes ago";
    }
    else
    {
	$val = sprintf "%.1f", $age/3660;
	$rows{$age} .= $val eq "1.0" ? "1 hour ago" : "$val hours ago";
    }
    $rows{$age} .= "</nobr></td></tr>\n";
}

if(keys %rows)
{
    foreach(sort keys %rows) { print $rows{$_} }
}
else
{
    print "<tr><td>none</td></tr>\n";
}

print "<tr><td>&nbsp;</td></tr>\n";
print "<tr><th align='left'>OLSR Entries</th></tr>\n";
print "<tr><td colspan=7><hr></td></tr>\n";
print "<tr><td>Total</td><td>&nbsp;</td><td align='right'>$olsrTotal</td></tr>\n";
print "<tr><td>Nodes</td><td>&nbsp;</td><td align='right'>$olsrNodes</td></tr>\n";
print "</table></td></tr></table>\n";

# end
print "</center>\n";
print "</form>\n";

if($debug)
{
    print "<pre>\n";
    print "localhosts\n";
    foreach $ip (sort keys %localhosts)
    {
	printf "%s %s", $ip, $localhosts{$ip}{name};
	printf "/%s", $localhosts{$ip}{tactical} if $localhosts{$ip}{tactical};
	foreach(@{$localhosts{$ip}{hosts}}) { print ":$_" }
	print "\n";
    }

    print "\nhosts\n";
    foreach $ip (sort keys %hosts)
    {
	$hosts{$ip}{name} = "" unless $hosts{$ip}{name};
	printf "%s %s", $ip, $hosts{$ip}{name};
	printf "/%s", $hosts{$ip}{tactical} if $hosts{$ip}{tactical};
	foreach(@{$hosts{$ip}{hosts}}) { print ":$_" }
	printf(" %d", $hosts{$ip}{mid}) if $hosts{$ip}{mid};
    }

    print "\nlinks\n";
    foreach(sort keys %links)
    {
	print "$_\n";
    }

    print "</pre>\n";
}

show_debug_info();
show_parse_errors();

page_footer();
print "</body>\n";
print "</html>\n";

