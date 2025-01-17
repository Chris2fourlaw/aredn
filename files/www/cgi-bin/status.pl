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

# collect some variables
$node = nvram_get("node");
$node = "NOCALL" if $node eq "";
$tactical = nvram_get("tactical");
$config = nvram_get("config");
$config = "not set" if $config eq "" or not -d "/etc/config.mesh";
$wifi_iface = get_interface("wifi");
$wifi_iface =~ /wlan(\d+)/;
$radio = ( defined $1 )? "radio$1" : "radio0";
$wifi_disable = ( $wifi_iface =~ /eth.*$/ )? 1 : 0;

if ( ! $wifi_disable )
{
  ($junk, $wifi_channel) = &uci_get_named_option("wireless", "$radio", "channel");
  if ($wifi_channel >= 76 and $wifi_channel <= 99)
  {
    $wifi_channel = ($wifi_channel*5+3000);
  }
  ($junk, $wifi_chanbw) = &uci_get_named_option("wireless", "$radio", "chanbw");

  $wifi_ssid = "N/A";
  @wisections = &uci_get_all_indexed_by_sectiontype("wireless", "wifi-iface");
  foreach(@wisections) {
    if ($_->{network} eq "wifi") {
      $wifi_ssid = $_->{ssid};
    }
  }
}

$node_desc = `/sbin/uci -q get system.\@system[0].description`; #pull the node description from uci
#get location info if available
$lat_lon = "<strong>Location Not Available</strong>";
$lat=&uci_get_indexed_option("aredn","location",0,"lat");
$lon=&uci_get_indexed_option("aredn","location",0,"lon");

if($lat ne "" and $lon ne "") {
	$lat_lon = "<center><strong>Location: </strong> $lat $lon</center>";
}
$olsrTotal = `/sbin/ip route list table 30 | wc -l`; #num hosts olsr is keeping track of
$olsrNodes = `/sbin/ip route list table 30 | egrep "/" | wc -l`; #num *nodes* on the network (minus other hosts)

read_postdata();

if($parms{css} and -f "/www/$parms{css}" and $parms{css} =~ /\.css$/i) {
  unlink "/tmp/web/style.css";
  symlink "/www/$parms{css}","/tmp/web/style.css";
}

# generate the page
http_header();
html_header("$node status", 1);
print "<body><form method='post' action='/cgi-bin/status' enctype='multipart/form-data'>\n";
print "<center>\n";

alert_banner();

# page header
print "<h1><big>$node";
print " / $tactical" if $tactical;
print "</big></h1>";
print "<center>$lat_lon</center>"; #display location info
print "<table id='node_description_display'><tr><td>$node_desc</td></tr></table>" if $node_desc;
print "<hr>\n";

# nav buttons
print "<nobr>\n";

#print qq(<button type=button onClick='window.open("/help.html", "_blank")' title='Open a help window'>Help</button>\n);
print "<a href='/help.html' target='_blank'>Help</a>\n";

print "&nbsp;&nbsp;&nbsp;";
print "<input type=submit name=refresh value=Refresh title='Refresh this page'>\n";

if($config eq "mesh")
{
    print "&nbsp;&nbsp;&nbsp;";
    print "<button type=button onClick='window.location=\"mesh\"' title='See what is on the mesh'>Mesh Status</button>\n";
    if ( ! $wifi_disable )
    {
	print "&nbsp;&nbsp;&nbsp;";
	print "<button type=button onClick='window.location=\"scan\"' title='See what wireless networks are nearby'>WiFi Scan</button>\n";
    }
}

print "&nbsp;&nbsp;&nbsp;";
print "<button type=button onClick='window.location=\"setup\"' title='Configure this node'>Setup</button>\n";

print "&nbsp;&nbsp;&nbsp;";

print "<select name=\"css\" size=\"1\" onChange=\"form.submit()\" >";
css_options();
print "</select>";

print "</nobr>";

print "<input type=hidden name=reload value=reload>\n";


if($config eq "not set")
{
    print "<b><br><br>This node is not yet configured.<br>";
    print "Go to the setup page and set your node name and password.<br>\n";
    print "Click Save Changes, <u>even if you didn't make any changes</u>, then the node will reboot.</b>\n";
    print "<br><br>\n";
    print "<div style=\"max-width: 540px\; text-align: left\">\n";
    print "<p>This device can be configured to either permit or prohibit known encrypted traffic on its RF link. It is up to the user to decide which is appropriate based on how it will be used and the license under which it will be operated. These rules vary by country, frequency, and intended use. You are encouraged to read and understand these rules before going further.</p>";
    print "<p>This device is pre-configured with no restrictions as to the type of data being passed.</p>\n";
    print "<p>Follow these steps if <span style=\"text-decoration: underline\">you wish to prohibit</span>  known encrypted traffic on the RF link. These instructions will disappear, so copy them for your reference:</p>";
    print "<p><ol>\n";
    print "<li>Setup your node name and password as instructed at the top of this page</li>";
    print "<li>After you Save Changes allow your node to reboot</li>";
    print "<li>Return to the Node Status page and navigate to Setup &gt Administration</li>";
    print "<li>Obtain the blockknownencryption package from the AREDN&trade; website OR refresh the Package list (node must be connected to the internet)</li>";
    print "<li>Install the blockknownencryption package by uploading it or choosing it from the package drop-down list</li>";
    print "<li>Wait until the package installs and then reboot your node</li>";
    print "</ol></p>\n";
    print "</div>";
}

# status display

@col1 = @col2 = ();
$hide_local = 0;
$browser_ip = "";

# left column - network interface info

# show the Primary/Wifi address
($ip, $mask, $bcast, $net, $cidr) = get_ip4_network($wifi_iface);
$cidr = "/ $cidr" if $cidr;
if (! $wifi_disable )
{
 $str  = "<th align=right><nobr>Wifi address</nobr></th><td>$ip <small>$cidr</small><br>";
}
else
{
 $str  = "<th align=right><nobr>Primary address</nobr></th><td>$ip <small>$cidr</small><br>";
}

# $str .= "<small><nobr>" . get_ip6_addr($wifi_iface) . "</nobr></small></td>";
push @col1, $str;

# find out if the browser is on this node's lan
# if not, hide the local network details
($ip, $mask, $bcast, $net, $cidr) = get_ip4_network(get_interface("lan"));
if($ENV{REMOTE_ADDR} =~ /::ffff:([\d\.]+)/)
{
    $browser_ip = $1;
    $hide_local = 1 unless validate_same_subnet($browser_ip, $ip, $mask);
}

if($ip =~ /^10\./ or not $hide_local)
{
    $cidr = "/ $cidr" if $cidr;
    $str  = "<th align=right><nobr>LAN address</nobr></th><td>$ip <small>$cidr</small><br>";
    # $str .= "<small><nobr>" . get_ip6_addr(get_interface("lan")) . "</nobr></small></td>";
    push @col1, $str;
}

{
    my $wanintf = get_interface("wan");
    if(not $hide_local and not system "ifconfig $wanintf >/dev/null 2>&1")
    {
        ($ip, $mask, $bcast, $net, $cidr) = get_ip4_network("$wanintf");
        $cidr = "/ $cidr" if $cidr;
        $cidr = "" unless $cidr;
        $str  = "<th align=right><nobr>WAN address</nobr></th><td>$ip <small>$cidr</small><br>";
        # $str .= "<small><nobr>" . get_ip6_addr("$wanintf") . "</nobr></small></td>";
        push @col1, $str;
    }
}

$ip = get_default_gw();

if($ip =~ /^10\./ or not $hide_local)
{
    $str  = "<th align=right><nobr>default gateway</nobr></th><td>$ip";
    $str .= "<br><nobr>" .  mesh_ip2hostname($ip) . "</nobr>" if $ip =~ /^10\./;
    push @col1, $str . "</td>";
}

if($browser_ip)
{
    $str  = "<th align=right><nobr>your address</nobr></th><td>$browser_ip";
    $str .= "<br><nobr>" .  mesh_ip2hostname($browser_ip) . "</nobr>";# if $ip =~ /^10\./;
    push @col1, $str . "</td>";
}

if ( ! $wifi_disable )
{
  $str  = "<th align=right><nobr>SSID</nobr></th><td>$wifi_ssid";
  push @col1, $str . "</td>";

  $str  = "<th align=right><nobr>Channel</nobr></th><td>$wifi_channel";
  push @col1, $str . "</td>";

  $str  = "<th align=right><nobr>Bandwidth</nobr></th><td>$wifi_chanbw MHz";
  push @col1, $str . "</td>";
}

# right column - system info

if($config eq "mesh" and ! $wifi_disable )
{
    $str = "<th align=right valign=middle><nobr>Signal/Noise/Ratio</nobr></th><td valign=middle><nobr>";
    ($s, $n) = get_wifi_signal($wifi_iface);
    if($s eq "N/A") { $str .= "N/A" }
    else            { $str .= sprintf "<big><b>%d / %d / %d dB</b></big>", $s, $n, $s - $n }
    $str .= "&nbsp;&nbsp;&nbsp;";
    $str .= "<button type=button onClick='window.location=\"signal?realtime=1\"' title='Display continuous or archived signal strength on a chart'>Charts</button>\n";
    $str .= "</nobr></td>";
    push @col2, $str;
}

push @col2, "<th align=right><nobr>firmware version</nobr></th><td>" . `cat /etc/mesh-release`. "</td>";
push @col2, "<th align=right>system time</th><td>" . `date +'%a %b %e %Y<br>%T %Z'` . "</td>";

$uptime = `uptime`;
$uptime =~ s/^ ..:..:.. up //;
($uptime, $load) = $uptime =~ /(.*),  load average: (.*)/;
push @col2, "<th align=right>uptime<br>load average</th><td>$uptime<br>$load</td>";

$str  = "<th align=right>free space</th><td><nobr>flash = ";
$space = get_free_space("/overlay");
$str .= $space < 100 ? "<blink><b>$space KB</b></blink>" : "$space KB";
$str .= "</nobr><br><nobr>/tmp = ";
$space = get_free_space("/tmp");
$str .= $space < 3000 ? "<blink><b>$space KB</b></blink>" : "$space KB";
$str .= "</nobr><br><nobr>memory = ";
$space = get_free_mem();
$str .= $space < 500 ? "<blink><b>$space KB</b></blink>" : "$space KB";
$str .= "</nobr></td>";

push @col2, $str;
push @col2, "<th align='right'>OLSR Entries</th><td><nobr>Total = $olsrTotal<nobr><br><nobr>Nodes = $olsrNodes<nobr></td>"; #display OLSR numbers

# now print the tables

print "<br><br><table>\n";
print "<tr><td valign=top><table cellpadding=4>\n";
foreach(@col1) { print "<tr>$_</tr>\n" }
print "</table></td><td valign=top><table cellpadding=4>\n";
foreach(@col2) { print "<tr>$_</tr>\n" }
print "</table></td></tr></table>\n";

# end
print "</center>\n";
print "</form>\n";

show_debug_info();
show_parse_errors();

page_footer();
print "</body>\n";
print "</html>\n";
