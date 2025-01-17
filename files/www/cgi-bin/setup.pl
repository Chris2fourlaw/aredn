#!/usr/bin/perl
=for comment

  Part of AREDN -- Used for creating Amateur Radio Emergency Data Networks
  Copyright (C) 2019 Joe Ayers AE6XE
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
use channelmaps;
use ucifunc;
#
# load the config parms
#

# test for web connectivity (for maps)
$pingOk=is_online();

@output = ();
@errors = ();

read_postdata();

my $tz_db_strings = tz_names_hash();
my $tz_db_names = tz_names_array();
$wifiintf = get_interface("wifi");
$phy = get_wlan2phy("$wifiintf");
chomp ($phycount = `ls -1d /sys/class/ieee80211/* | wc -l`);

my @ctwo=(1,2,3,4,5,6,7,8,9,10,11);
my @cfive=(36,40,44,48,149,153,157,161,165);

if($parms{button_uploaddata})
{
    my $si=`curl 'http://localnode:8080/cgi-bin/sysinfo.json?hosts=1' 2>/dev/null`;
    # strip closing }\n from si
    chomp($si);
    chop($si);

    # get olsrd topo information
    my $topo=`curl 'http://localnode:9090/links' 2>/dev/null`;
    chomp($topo);
    # add topo subdoc and close root doc
    my $newsi= sprintf "%s,\"olsr\": %s}",$si, $topo;

    # PUT it to the server
    my $upcurl=`curl -H 'Accept: application/json' -X PUT -d '$newsi' http://data.arednmesh.org/sysinfo`;
    if($? == 0) {
        push @output, "AREDN online map updated";
    } else {
        push @errors, "ERROR: Cannot update online map. Please ensure this node has access to the internet.";
    }
}

# convert the %parms into scalars for convenience
if($parms{button_default})
{
    load_cfg("/etc/config.mesh/_setup.default");
    foreach(keys %cfg)
    {
	eval (sprintf "\$$_ = \"%s\"", quotemeta $cfg{$_});
    }
}
else
{
    foreach(keys %parms)
    {
	next unless /^\w+$/;
	$parms{$_} =~ s/^\s+//;
	$parms{$_} =~ s/\s+$//;
	eval (sprintf "\$$_ = \"%s\"", quotemeta $parms{$_});
    }

    if($button_reset or not keys %parms)
    {
	load_cfg("/etc/config.mesh/_setup");
	foreach(keys %cfg)
	{
	    eval (sprintf "\$$_ = \"%s\"", quotemeta $cfg{$_});
	}
	$wifi2_key =~ s/([a-f0-9][a-f0-9])/chr(hex($1))/eg;
	$wifi2_ssid =~ s/([a-f0-9][a-f0-9])/chr(hex($1))/eg;
	$wifi3_key =~ s/([a-f0-9][a-f0-9])/chr(hex($1))/eg;
	$wifi3_ssid =~ s/([a-f0-9][a-f0-9])/chr(hex($1))/eg;
    }
}

if($parms{button_reset} or $parms{button_default} or (not $nodetac and not keys %parms))
{
    $nodetac = nvram_get("node");
    $tactical = nvram_get("tactical");
    $nodetac .= " / $tactical" if $tactical;
}
else
{
    $nodetac = $parms{nodetac};
}

# make sure unchecked checkboxes are accounted for
foreach(qw(lan_dhcp olsrd_bridge olsrd_gw wifi2_enable lan_dhcp_noroute wifi_enable wifi3_enable))
{
    $parms{$_} = 0 unless $parms{$_};
}

# lan is always static
$lan_proto = "static";

# enforce direct mode settings
# (formerly known as dmz mode)
$dmz_mode = 2 if $dmz_mode != 0 and $dmz_mode < 2;
$dmz_mode = 5 if $dmz_mode > 5;

if($dmz_mode)
{
    $ipshift = (ip2decimal($wifi_ip) << $dmz_mode) & 0xffffff;
    $dmz_lan_ip = add_ip_address("1" . decimal2ip($ipshift), 1);
    $dmz_lan_mask = decimal2ip(0xffffffff << $dmz_mode);
    ($octet) = $dmz_lan_ip =~ /\d+\.\d+\.\d+\.(\d+)/;
    $dmz_dhcp_start = $octet + 1;
    $dmz_dhcp_end = $dmz_dhcp_start + (1 << $dmz_mode) - 4;
    $parms{dmz_lan_ip}     = $dmz_lan_ip;
    $parms{dmz_lan_mask}   = $dmz_lan_mask;
    $parms{dmz_dhcp_start} = $dmz_dhcp_start;
    $parms{dmz_dhcp_end}   = $dmz_dhcp_end;
}

# derive values which are not explicitly defined
$parms{dhcp_limit} = $dhcp_end - $dhcp_start + 1;
$parms{dmz_dhcp_limit} = $dmz_dhcp_end - $dmz_dhcp_start + 1;

#
# get the active wifi settings on a fresh page load
#

unless($parms{reload})
{
    ($wifi_txpower) = `iwinfo $wifiintf info 2>/dev/null` =~ /Tx-Power: (\d+)/;
    (my $doesiwoffset) = `iwinfo $wifiintf info 2>/dev/null` =~ /TX power offset: (\d+)/;
    if ( $doesiwoffset ) {
        $wifi_txpower -= $1;
    }
}

# sanitize the active settings
$wifi_txpower = wifi_maxpower($wifi_channel) if not defined $wifi_txpower or $wifi_txpower > wifi_maxpower($wifi_channel);
$wifi_txpower = 1 if $wifi_txpower < 1;
$wifi_distance = 0 unless defined $wifi_distance;
$wifi_distance = 0 if $wifi_distance =~ /\D/;

# stuff the sanitized data back into the parms hash
# so they get saved correctly
$parms{wifi_distance} = $wifi_distance;
$parms{wifi_txpower} = $wifi_txpower;

#
# apply the wifi settings
#

if(($parms{button_apply} or $parms{button_save}) and $wifi_enable )
{
    if($wifi_distance < 0 or $wifi_distance =~ /\D/)
    {
        push (@errors, "invalid distance value");
    } else {
        $cmd = "";
	if ( $wifi_distance eq "0" )
	{
            $cmd .= "iw phy ${phy} set distance auto >/dev/null 2>&1;";
	}
	else
	{
	    $cmd .= "iw phy ${phy} set distance $wifi_distance >/dev/null 2>&1;";
	}
        $cmd .= "iw dev $wifiintf set txpower fixed ${wifi_txpower}00 >/dev/null 2>&1;";
        system $cmd;
    }

}

if($parms{button_updatelocation})
{
    # Process gridsquare -----------------------------------
    if($parms{gridsquare})
    {
        # validate values
        if($parms{gridsquare} =~ /^[A-Z][A-Z]\d\d[a-z][a-z]$/)
        {
            # set values/commit
            $rc=&uci_set_indexed_option("aredn","location",0,"gridsquare", $parms{gridsquare});
            $rc=&uci_commit("aredn");
            &uci_clone("aredn");
            push @errors, "Cannot save gridsquare in uci" if $rc ne "0";
            push @output, "Gridsquare updated.\n";
        } else {
            push @errors, "ERROR: Gridsquare format is: 2-uppercase letters, 2-digits, 2-lowercase letters. (AB12cd)\n";
        }
    } else {
       $rc=&uci_set_indexed_option("aredn","location",0,"gridsquare", "");
       $rc=&uci_commit("aredn");
       &uci_clone("aredn");
       push @output, "Gridsquare purged.\n";
    }

    # Process LAT/LNG ---------------------------------------------
    if($parms{latitude} and $parms{longitude})
    {
        # validate values
        if($parms{latitude} =~ /^([-+]?\d{1,2}([.]\d+)?)$/ and $parms{longitude} =~ /^([-+]?\d{1,3}([.]\d+)?)$/) {
            if($parms{latitude} >= -90 and $parms{latitude} <= 90 and $parms{longitude} >= -180 and $parms{longitude} <= 180) {
                # set values/commit
                $rc=&uci_set_indexed_option("aredn","location",0,"lat", $parms{latitude});
                $rc=&uci_set_indexed_option("aredn","location",0,"lon", $parms{longitude});
                $rc=&uci_commit("aredn");
                &uci_clone("aredn");
                push @errors, "Cannot save latitude/longitude in uci" if $rc ne "0";
                push @output, "Lat/lon updated.\n";
            } else {
                push @errors, "ERROR: Lat/lon values must be between -90/90 and -180/180, respectively.\n";
            }
        } else {
            push @errors, "ERROR: Lat/lon format is decimal: (ex. 30.121456 or -95.911154)\n";
        }
    } else {
       $rc=&uci_set_indexed_option("aredn","location",0,"lat", "");
       $rc=&uci_set_indexed_option("aredn","location",0,"lon", "");
       $rc=&uci_commit("aredn");
       &uci_clone("aredn");
       push @output, "Lat/lon purged.\n";
    }
}

#
# retrieve location data
#
$lat=&uci_get_indexed_option("aredn","location",0,"lat");
$lon=&uci_get_indexed_option("aredn","location",0,"lon");
$gridsquare=&uci_get_indexed_option("aredn","location",0,"gridsquare");


# validate and save configuration
if($parms{button_save})
{
    # lookup the tz string for the selected time_zone
    $time_zone = $$tz_db_strings{$time_zone_name};
    $parms{time_zone} = $time_zone;

    if(not validate_netmask($wifi_mask))
    {
	push @errors, "invalid Mesh netmask";
    }
    elsif(not validate_ip_netmask($wifi_ip, $wifi_mask))
    {
	push @errors, "invalid Mesh IP address";
    }

    push (@errors, "invalid Mesh RF SSID") unless length $wifi_ssid <= 32;

    if ( is_channel_valid($wifi_channel) != 1 )
    {
        push (@errors, "invalid Mesh RF channel")
    }

    if ( !is_wifi_chanbw_valid($wifi_chanbw,$wifi_ssid) )
    {
        push (@errors, "Invalid Mesh RF channel width");
        $wifi_chanbw = 20;
    }

    $wifi_country_validated=0;
    foreach my $testcountry (split(',',"00,HX,AD,AE,AL,AM,AN,AR,AT,AU,AW,AZ,BA,BB,BD,BE,BG,BH,BL,BN,BO,BR,BY,BZ,CA,CH,CL,CN,CO,CR,CY,CZ,DE,DK,DO,DZ,EC,EE,EG,ES,FI,FR,GE,GB,GD,GR,GL,GT,GU,HN,HK,HR,HT,HU,ID,IE,IL,IN,IS,IR,IT,JM,JP,JO,KE,KH,KP,KR,KW,KZ,LB,LI,LK,LT,LU,LV,MC,MA,MO,MK,MT,MY,MX,NL,NO,NP,NZ,OM,PA,PE,PG,PH,PK,PL,PT,PR,QA,RO,RS,RU,RW,SA,SE,SG,SI,SK,SV,SY,TW,TH,TT,TN,TR,UA,US,UY,UZ,VE,VN,YE,ZA,ZW")) {
        if ( $testcountry eq $wifi_country ) {
            $wifi_country_validated=1;
            last;
        }
    }
    if ( $wifi_country_validated ne 1 ) {
        $wifi_country="00";
        push (@errors, "Invalid country");
    }


    if($lan_proto eq "static")
    {
	if(not validate_netmask($lan_mask))
	{
	    push @errors, "invalid LAN netmask";
	}
	elsif($lan_mask !~ /^255\.255\.255\./)
	{
	    push @errors, "LAN netmask must begin with 255.255.255";
	}
	elsif(not validate_ip_netmask($lan_ip, $lan_mask))
	{
	    push @errors, "invalid LAN IP address";
	}
	else
	{
	    if($lan_dhcp)
	    {
		my $start_addr = change_ip_address($lan_ip, $dhcp_start);
		my $end_addr   = change_ip_address($lan_ip, $dhcp_end);

		unless(validate_ip_netmask($start_addr, $lan_mask) and
		       validate_same_subnet($start_addr, $lan_ip, $lan_mask))
		{
		    push @errors, "invalid DHCP start address";
		}

		unless(validate_ip_netmask($end_addr, $lan_mask) and
		       validate_same_subnet($end_addr, $lan_ip, $lan_mask))
		{
		    push @errors, "invalid DHCP end address";
		}

		if($dhcp_start > $dhcp_end)
		{
		    push @errors, "invalid DHCP start/end addresses";
		}
	    }

	    if($lan_gw and not
	       (validate_ip_netmask($lan_gw, $lan_mask) and
		validate_same_subnet($lan_ip, $lan_gw, $lan_mask)))
	    {
		push @errors, "invalid LAN gateway";
	    }
	}
    }

    if($wan_proto eq "static")
    {
	if(not validate_netmask($wan_mask))
	{
	    push @errors, "invalid WAN netmask";
	}
	elsif(not validate_ip_netmask($wan_ip, $wan_mask))
	{
	    push @errors, "invalid WAN IP address";
	}
	else
	{
	    unless (validate_ip_netmask($wan_gw, $wan_mask) and
		    validate_same_subnet($wan_ip, $wan_gw, $wan_mask))
	    {
		push @errors, "invalid WAN gateway";
	    }
	}
    }

    push (@errors, "invalid WAN DNS 1") unless validate_ip($wan_dns1);
    push (@errors, "invalid WAN DNS 2") if $wan_dns2 ne "" and not validate_ip($wan_dns2);


    if($passwd1 or $passwd2)
    {
	push (@errors, "passwords do not match") if $passwd1 ne $passwd2;
	push (@errors, "passwords cannot contain '#'") if $passwd1 =~ /#/;
	push (@errors, "password must be changed") if $passwd1 eq "hsmm";
    }
    elsif(-f "/etc/config/unconfigured")
    {
	push @errors, "password must be changed during initial configuration";
    }

    if($nodetac =~ /\//)
    {
	$nodetac =~ /^\s*([\w\-]+)\s*\/\s*([\w\-]+)\s*$/;
	$node = $1;
	$tactical = $2;
	push(@errors, "invalid node/tactical name") if not $2;
    }
    else
    {
	$node = $nodetac;
	$tactical = "";
	push(@errors, "you must set the node name") if $node eq "";
    }

    if($node and ($node =~ /[^\w\-]/ or $node =~ /_/))
    {
	push(@errors, "invalid node name");
    }

    if($tactical =~ /[^\w\-]/ or $tactical =~ /_/)
    {
	push(@errors, "invalid tactical name");
    }

    if($ntp_server eq '' || validate_fqdn($ntp_server) == 0)
    {
    push(@errors, "invalid ntp server");
    }

    if( length( $wifi2_ssid ) > 32 )
    {
	push (@errors, "LAN Access Point SSID must be 32 or less characters ");
    }

    if( "$wifi2_enable" eq "1" and (length( $wifi2_key ) < 8 or length($wifi2_key) > 64) )
    {
	push (@errors, "LAN Access Point Password must be at least 8 characters, up to 64");
    }
    if( "$wifi3_enable" eq "1" and (length( $wifi3_key ) < 8 or length($wifi3_key) > 64) and ! length($wifi3_key) == 0)
    {
	push (@errors, "WAN Wifi Client Password must be between 8 and 64 characters");
    }
    if( "$wifi2_enable" eq "1" and ( $wifi2_key =~ /\'/ or $wifi2_ssid =~ /\'/ ))
    {
	push (@errors, "The LAN Access Point password and ssid may not contain a single quote character");
    }
    if( "$wifi3_enable" eq "1" and ( $wifi3_key =~ /\'/ or $wifi3_ssid =~ /\'/ ))
    {
	push (@errors, "The WAN Wifi Client password and ssid may not contain a single quote character");
    }

    if ( $wifi2_channel < 30 and "$wifi2_hwmode" eq "11a" )
    {
        push (@errors, "Changed to 5GHz Mesh LAN AP, please review channel selection");
    }
    if ( $wifi2_channel > 30 and "$wifi2_hwmode" eq "11g" )
    {
        push (@errors, "Changed to 2GHz Mesh LAN AP, please review channel slection");
    }
    if ( $phycount > 1 and $wifi_enable and $wifi2_channel < 36 and $wifi2_enable )
    {
	push (@errors, "Mesh RF and LAN Access Point can not both use the same wireless card, review LAN AP settings");
    }
    if ( $phycount > 1 and ! $wifi_enable and $wifi2_hwmode eq $wifi3_hwmode )
    {
	push (@errors, "Some settings auto updated to avoid conflicts, please review and save one more time");
    }
    if ( $wifi_enable and $wifi2_enable and $wifi3_enable )
    {
	push (@errors, "Can not enable Mesh RF, LAN AP, and WAN Wifi Client with only 2 wireless cards, WAN Wifi Client turned off");
	$wifi3_enable = 0;
    }
    if ( $phycount == 1 and $wifi_enable and ($wifi2_enable or $wifi3_enable ))
    {
	push (@errors, "Can not enable Mesh RF along with LAN AP or WAN Wifi Client. Only Mesh RF enabled now, please review settings.");
	$wifi2_enable = 0;
	$wifi3_enable = 0;
    }

    if($debug == 3) # don't save the config, just validate it
    {
	push (@errors, "OK") unless @errors;
    }

    unless(@errors)
    {
	$parms{node} = $node;
	$parms{tactical} = $tactical;
	system "touch /tmp/unconfigured" if -f "/etc/config/unconfigured";
	$parms{wifi2_key} =~ s/(.)/sprintf("%x",ord($1))/eg;
	$parms{wifi2_ssid} =~ s/(.)/sprintf("%x",ord($1))/eg;
	$parms{wifi3_key} =~ s/(.)/sprintf("%x",ord($1))/eg;
	$parms{wifi3_ssid} =~ s/(.)/sprintf("%x",ord($1))/eg;
	$rc = save_setup("/etc/config.mesh/_setup");
	$rc2 = &uci_commit("system");
	if(-s "/tmp/web/save/node-setup.out")
	{
	    push @errors, `cat /tmp/web/save/node-setup.out`;
	}
	elsif(not $rc)
	{
	    push @errors, "error saving setup";
	}
	reboot_page("/cgi-bin/status") if -f "/tmp/unconfigured" and not @errors;
    }
}

system "rm -rf /tmp/web/save";

reboot_page("/cgi-bin/status") if $parms{button_reboot};

#
# retrieve node description
#
$desc = &uci_get_indexed_option("system", "system", 0, "description");
#
# Retreive map url, css, and js locations
#
my ($rc, $maptiles, $leafletcss, $leafletjs);
($rc, $maptiles)=&uci_get_indexed_option("aredn","map",0,"maptiles");
($rc, $leafletcss)=&uci_get_indexed_option("aredn","map",0,"leafletcss");
($rc, $leafletjs)=&uci_get_indexed_option("aredn","map",0,"leafletjs");

#
# generate the page
#

http_header() unless $debug == 2;
html_header(nvram_get("node") . " setup", 0);

print <<EOF;
<script>

function loadCSS(url, callback) {
   var head = document.getElementsByTagName('head')[0];
   var stylesheet = document.createElement('link');
   stylesheet.rel = 'stylesheet';
   stylesheet.type = 'text/css';
   stylesheet.href = url;
   stylesheet.onload = callback;

   head.appendChild(stylesheet);
}  

function loadScript(url, callback) {
   var head = document.getElementsByTagName('head')[0];
   var script = document.createElement('script');
   script.type = 'text/javascript';
   script.src = url;
   script.onload = callback;

   head.appendChild(script);
}

var map;
var marker;

var leafletLoad = function() {
    map = L.map('map').setView([0.0, 0.0], 1);
    var dotIcon = L.icon({iconUrl: '/dot.png'});
EOF
print "L.tileLayer('$maptiles',";
print <<EOF;
    {
        maxZoom: 18,
        attribution: 'Map data &copy; <a href="http://openstreetmap.org">OpenStreetMap</a> contributors, ' +
            '<a href="http://creativecommons.org/licenses/by/3.0/">CC BY 3.0</a>, ' +
            'Imagery &copy;<a href="http://stamen.com">Stamen Design</a>',
        id: 'mapbox.streets'
    }).addTo(map);
EOF

if($lat and $lon)
{
    print "marker= new L.marker([$lat,$lon],{draggable: true, icon: dotIcon});";
    print "map.addLayer(marker);";
    print "map.setView([$lat,$lon],13);";
    print "marker.on('drag', onMarkerDrag);";
} else {
    print "map.on('click', onMapClick);";
}

print <<EOF;
}

function onMapClick(e) {
    marker= new L.marker(e.latlng.wrap(),{draggable: true, icon: dotIcon});
    map.addLayer(marker);
    document.getElementsByName('latitude')[0].value=e.latlng.wrap().lat.toFixed(6).toString();
    document.getElementsByName('longitude')[0].value=e.latlng.wrap().lng.toFixed(6).toString();
    map.off('click', onMapClick);
    marker.on('drag', onMarkerDrag);
}

function onMarkerDrag(e) {
    var m = e.target;
    var p = m.getLatLng().wrap();
    document.getElementsByName('latitude')[0].value=p.lat.toFixed(6).toString();
    document.getElementsByName('longitude')[0].value=p.lng.toFixed(6).toString();
}

EOF

# On page load, attempt loading of Leaflet CSS, then Leaflet JS if that works, and finally initialise the map if both have worked.
if(($pingOk) || ($leafletcss =~ ".local.mesh" && $leafletjs =~ ".local.mesh")) {
    print "window.onload = function (event) { loadCSS('${leafletcss}',function () { loadScript('${leafletjs}', leafletLoad); }); };";
}
print <<EOF;

function findLocation() {
    navigator.geolocation.getCurrentPosition(foundLocation, noLocation);
}

function foundLocation(position) {
    var jlat = position.coords.latitude;
    var jlon = position.coords.longitude;
    // update the fields
    document.getElementsByName('latitude')[0].value=jlat.toFixed(6).toString();
    document.getElementsByName('longitude')[0].value=jlon.toFixed(6).toString();

    // try to update the map if Javascript libs have been loaded
    if (typeof L != 'undefined') {
        var latlng = L.latLng(jlat, jlon);
        marker.setLatLng(latlng);
        map.setView(latlng,13);
    }
}

function noLocation() {
    alert('Could not find location.  Try pinning it on the map.');
}

function updDist(x) {
    var dvs= calcDistance(x);
    var xcm=dvs['miles'];
    var xc=dvs['meters'];
    var xck=dvs['kilometers'];

    var distBox = document.getElementById('dist');
    var dist_meters=document.getElementsByName('wifi_distance')[0];
    document.getElementsByName('wifi_distance_disp_miles')[0].value = xcm;
    document.getElementsByName('wifi_distance_disp_km')[0].value = xck;
    document.getElementsByName('wifi_distance_disp_meters')[0].value = xc;
    dist_meters.value = xc;

    // default of 0 means 'auto', so full range is always dist-norm
    distBox.className = 'dist-norm';
}

function calcDistance(x) {
    // x is in KILOMETERS
    var dvs = new Object();
    dvs['miles']=(x*0.621371192).toFixed(2);
    dvs['meters']=Math.ceil(x*1000);
    dvs['kilometers']=x;
    return dvs;
}

function doSubmit() {
    var desc_text = document.mainForm.description_node.value;
    var singleLine = desc_text.replace(new RegExp( "\\n", "g" ), " ");
    document.mainForm.description_node.value = singleLine;
    return true;
}

function toggleMap(toggleButton) {
    var mapdiv=document.getElementById('map');
    if(toggleButton.value=='hide') {
        // HIDE IT
        mapdiv.style.display='none';
        toggleButton.value='show';
        toggleButton.innerHTML='Show Map';
    } else {
        // SHOW IT
        mapdiv.style.display='block';
        toggleButton.value='hide';
        toggleButton.innerHTML='Hide Map';
    }
    // force the map to redraw
    if(typeof map !== 'undefined') map.invalidateSize();
    return false;
}

</script>
EOF

print "</head>";
print "<body><center>\n";

alert_banner();
print "<form onSubmit='doSubmit();' name='mainForm' method=post action=/cgi-bin/setup.pl enctype='multipart/form-data'>\n" unless $debug == 2;
print "<form method=post action=test>\n" if $debug == 2;

print "<table width=790>\n";
print "<tr><td>\n";
navbar("setup");
print "</td></tr>\n";

#
# control buttons
#

print "<tr><td align=center>
<a href='/help.html#setup' target='_blank'>Help</a>
&nbsp;&nbsp;&nbsp;
<input type=submit name=button_save value='Save Changes' title='Store these settings'>&nbsp;
<input type=submit name=button_reset value='Reset Values' title='Revert to the last saved settings'>&nbsp;
<input type=submit name=button_default value='Default Values' title='Set all values to their default'>&nbsp;
<input type=submit name=button_reboot value=Reboot style='font-weight:bold' title='Immediately reboot this node'>
</td></tr>
<tr><td>&nbsp;</td></tr>\n";

# messages
if(@output)
{
    # print "<tr><th>Configuration NOT saved!</th></tr>\n";
    print "<tr><td align=center><table>\n";
    print "<tr><td><ul style='padding-left:0'>\n";
    foreach(@output) { print "<li>$_</li>\n" }
    print "</ul></td></tr></table>\n";
    print "</td></tr>\n";
}

if(@errors)
{
    print "<tr><th>Configuration NOT saved!</th></tr>\n";
    print "<tr><td align=center><table>\n";
    print "<tr><td><ul style='padding-left:0'>\n";
    foreach(@errors) { print "<li>$_</li>\n" }
    print "</ul></td></tr></table>\n";
    print "</td></tr>\n";
}
elsif($parms{button_save})
{
    print "<tr><td align=center>";
    print "<b>Configuration saved.</b><br><br>\n";
    print "</td></tr>\n";
}

if(not @errors and -f "/tmp/reboot-required")
{
    print "<tr><td align=center><h3>Reboot is required for changes to take effect</h3></td></tr>";
}

#
# node name and type, password
#

print "<tr><td align=center>\n";
print "<table cellpadding=5 border=0>

<tr>
<td>Node Name</td>
<td><input type=text name=nodetac value='$nodetac' tabindex=1 size='50'></td>
<td align=right>Password</td>
<td><input type=password name=passwd1 value='$passwd1' size=8 tabindex=2></td>";

if(0)# disable for now
{
    print "<td>&nbsp;</td>";
    print "<td align=right>Latitude</td>";
    print "<td><input type=text size=8 name=aprs_lat value='$aprs_lat' tabindex=4></td>\n";
}

print "
</tr>
<tr>
<td>Node Description (optional)</td>
<td><textarea rows='2' cols='60' wrap='soft' maxlength='210' id='node_description_entry' name='description_node' tabindex='4'>$desc</textarea></td>";
push @hidden, "<input type=hidden name=config value='mesh'>";
print "
<td>Verify Password</td>
<td><input type=password name=passwd2 value='$passwd2' size=8 tabindex=3></td>";

print "
</tr>
</table>
</td></tr>";

print "<tr><td><br>";
print "<table cellpadding=5 border=1 width=100%><tr><td valign=top width=33%>\n";

#
# MESH RF settings
#

print "<table width=100% style='border-collapse: collapse;'>";
if ( $phycount > 1 )
    {
	print " <tr><th colspan=2>Mesh RF (2GHz)</th></tr>";
    }
    else
    {
        print " <tr><th colspan=2>Mesh RF</th></tr>";
    }

push @hidden, "<input type=hidden name=wifi_proto value='static'>";

# add enable/disable
#

print "\n<tr><td>Enable</td>";
print "<td><input type=checkbox name=wifi_enable value=1";
print " checked" if $wifi_enable;
print "></td></tr>\n";

print "<tr><td><nobr>IP Address</nobr></td>\n";
print "<td><input type=text size=15 name=wifi_ip value='$wifi_ip'></td></tr>\n";
print "<tr><td>Netmask</td>\n";
print "<td><input type=text size=15 name=wifi_mask value='$wifi_mask'></td></tr>\n";

# Reset wifi channel/bandwidth to default
if ( -f "/etc/config/unconfigured" || $parms{button_reset} ) {
    my $defaultwifi = rf_default_channel();
    $wifi_channel = $defaultwifi->{'channel'};
    $wifi_chanbw = $defaultwifi->{'chanbw'};
}

if ( ${wifi_enable} )
{
    print "<tr><td>SSID</td>\n";
    print "<td><input type=text size=15 name=wifi_ssid value='$wifi_ssid'>";
    print "-$wifi_chanbw-v3</td></tr>\n";

    push @hidden, "<input type=hidden name=wifi_mode value='$wifi_mode'>";

    print "<tr><td>Channel</td>\n";
    print "<td><select name=wifi_channel>\n";
    my $rfchannels=rf_channels_list();
    foreach  $channelnumber (sort {$a <=> $b} keys %{$rfchannels} )
    {
        selopt($rfchannels->{$channelnumber}, $channelnumber, $wifi_channel);
    }
    print "</select>&nbsp;&nbsp;<a href=\"/help.html\#channel\" target=\"_blank\"><img src=\"/qmark.png\"></a></td></tr>\n";

    print "<tr><td>Channel Width</td>\n";
    print "<td><select name=wifi_chanbw>\n";
    selopt("20 MHz","20",$wifi_chanbw);
    selopt("10 MHz","10",$wifi_chanbw);
    selopt("5 MHz","5",$wifi_chanbw);
    print "</select></td></tr>\n";

    push (@hidden, "<input type=hidden name=wifi_country value='HX'>");

    print "<tr><td colspan=2 align=center><hr><small>Active Settings</small></td></tr>\n";

    print "<tr><td><nobr>Tx Power</nobr></td>\n";
    print "<td><select name=wifi_txpower>\n";
    my $txpoweroffset = wifi_txpoweroffset();
    for($i = wifi_maxpower($wifi_channel); $i >= 1; --$i) { selopt($i+$txpoweroffset ." dBm", $i, $wifi_txpower) }
    print "</select>&nbsp;&nbsp;<a href=\"/help.html\#power\" target=\"_blank\"><img src=\"/qmark.png\"></a></td></tr>\n";

    print "<tr id='dist' class='dist-norm'><td>Distance to<br/>FARTHEST Neighbor<br/><h3>'0' is auto</h3></td>\n";

    $wifi_distance=int($wifi_distance);  # in meters
    $wifi_distance_disp_km=int($wifi_distance/1000);
    $wifi_distance_disp_miles=sprintf("%.2f",$wifi_distance_disp_km*.621371192);

    print "<td><input disabled size=6 type=text name='wifi_distance_disp_miles' value='$wifi_distance_disp_miles' title='Distance to the farthest neighbor'>&nbsp;mi<br />";
    print "<input disabled size=6 type=text size=4 name='wifi_distance_disp_km' value='$wifi_distance_disp_km' title='Distance to the farthest neighbor'>&nbsp;km<br />";
    print "<input disabled size=6 type=text size=4 name='wifi_distance_disp_meters' value='$wifi_distance' title='Distance to the farthest neighbor'>&nbsp;m<br />";

    print "<input id='distance_slider' type='range' min='0' max='150' step='1' value='$wifi_distance_disp_km' oninput='updDist(this.value)' onchange='updDist(this.value)' /><br />";
    print "<input type='hidden' size='6' name='wifi_distance' value='$wifi_distance' />";
    print "</td></tr>\n";

    print "<tr><td></td><td><input type=submit name=button_apply value=Apply title='Immediately use these active settings'></td></tr>\n";

}
else
{
    push @hidden, "<input type=hidden name=wifi_ssid value='$wifi_ssid'>";
    push @hidden, "<input type=hidden name=wifi_mode value='$wifi_mode'>";
    push @hidden, "<input type=hidden name=wifi_txpower value='$wifi_txpower'>";
    push @hidden, "<input type=hidden name=wifi_channel value='$wifi_channel'>";
    push @hidden, "<input type=hidden name=wifi_chanbw value='$wifi_chanbw'>";
    push @hidden, "<input type=hidden name=wifi_distance value='$wifi_distance'>";
    push (@hidden, "<input type=hidden name=wifi_country value='HX'>");
} 

print "</table></td>\n";

#
# LAN settings
#

print "<td valign=top width=33%><table width=100%>
<tr><th colspan=2>LAN</th></tr>
<tr>
<td>LAN Mode</td>
<td><select name=dmz_mode onChange='form.submit()'";
print ">\n";
selopt("NAT", 0, $dmz_mode);
selopt("1 host Direct", 2, $dmz_mode);
selopt("5 host Direct", 3, $dmz_mode);
selopt("13 host Direct", 4, $dmz_mode);
selopt("29 host Direct", 5, $dmz_mode);
print "</select></td>\n</tr>\n";
push @hidden, "<input type=hidden name=lan_proto value='static'>";

if($dmz_mode)
{
    print "<tr><td><nobr>IP Address</nobr></td>";
    #print "<td><input type=text size=15 name=dmz_lan_ip value='$dmz_lan_ip' disabled></td></tr>\n";
    print "<td>$dmz_lan_ip</td></tr>\n";
    push @hidden, "<input type=hidden name=dmz_lan_ip value='$dmz_lan_ip'>";

    print "<tr><td>Netmask</td>";
    #print "<td><input type=text size=15 name=dmz_lan_mask value='$dmz_lan_mask' disabled></td></tr>\n";
    print "<td>$dmz_lan_mask</td></tr>\n";
    push @hidden, "<input type=hidden name=dmz_lan_mask value='$dmz_lan_mask'>";

    print "<tr><td><nobr>DHCP Server</nobr></td>";
    print "<td><input type=checkbox name=lan_dhcp value=1";
    print " checked" if $lan_dhcp;
    print "></td></tr>\n";

    print "<tr><td><nobr>DHCP Start</nobr></td>";
    #print "<td><input type=text size=4 name=dmz_dhcp_start value='$dmz_dhcp_start' disabled></td></tr>\n";
    print "<td>$dmz_dhcp_start</td></tr>\n";
    push @hidden, "<input type=hidden name=dmz_dhcp_start value='$dmz_dhcp_start'>";

    print "<tr><td><nobr>DHCP End</nobr></td>";
    #print "<td><input type=text size=4 name=dmz_dhcp_end value='$dmz_dhcp_end' disabled></td></tr>\n";
    print "<td>$dmz_dhcp_end</td></tr>\n";

    push @hidden, "<input type=hidden name=lan_ip     value='$lan_ip'>";
    push @hidden, "<input type=hidden name=lan_mask   value='$lan_mask'>";
    push @hidden, "<input type=hidden name=dhcp_start value='$dhcp_start'>";
    push @hidden, "<input type=hidden name=dhcp_end   value='$dhcp_end'>";
    push @hidden, "<input type=hidden name=lan_gw     value='$lan_gw'>";
}
else
{
    print "<tr><td><nobr>IP Address</nobr></td>";
    print "<td><input type=text size=15 name=lan_ip value='$lan_ip'></td></tr>\n";

    print "<tr><td>Netmask</td>";
    print "<td><input type=text size=15 name=lan_mask value='$lan_mask'></td></tr>\n";

    if($wan_proto eq "disabled")
    {
	print "<tr><td>Gateway</td>";
	print "<td><input type=text size=15 name=lan_gw value='$lan_gw' title='leave blank if not needed'></td></tr>\n";
    }
    else
    {
	push @hidden, "<input type=hidden name=lan_gw     value='$lan_gw'>";
    }
    print "<tr><td><nobr>DHCP Server</nobr></td>";
    print "<td><input type=checkbox name=lan_dhcp value=1";
    print " checked" if $lan_dhcp;
    print "></td></tr>\n";

    print "<tr><td><nobr>DHCP Start</nobr></td>";
    print "<td><input type=text size=4 name=dhcp_start value='$dhcp_start'";
    print "></td></tr>\n";

    print "<tr><td><nobr>DHCP End</nobr></td>";
    print "<td><input type=text size=4 name=dhcp_end value='$dhcp_end'";
    print "></td></tr>\n";

    push @hidden, "<input type=hidden name=dmz_lan_ip     value='$dmz_lan_ip'>";
    push @hidden, "<input type=hidden name=dmz_lan_mask   value='$dmz_lan_mask'>";
    push @hidden, "<input type=hidden name=dmz_dhcp_start value='$dmz_dhcp_start'>";
    push @hidden, "<input type=hidden name=dmz_dhcp_end   value='$dmz_dhcp_end'>";

}

print "<tr><td colspan=2><hr></hr></td></tr>";

$M39model = `/usr/local/bin/get_model | grep -e "M[39]"`;
if ( ($phycount >  1 and (! $wifi_enable or  ! $wifi3_enable))
  or ($phycount == 1 and  ! $wifi_enable and ! $wifi3_enable )
 and ! $M39model )
{
    # LAN AP shows as an option 

    # Determine hardware options and set band and channels accordingly

    if ($phycount == 1)
    {
	$rc3 = system("iw phy phy0 info | grep -q '5180 MHz' > /dev/null");
	if ( $rc3 )
	{
	    $wifi2_hwmode="11g";
	    if ( $wifi2_channel > 14  ) { $wifi2_channel = 1; }
	    @chan=@ctwo;
	}
	else
	{
	    $wifi2_hwmode="11a";
	    if ( $wifi2_channel < 36 ) { $wifi2_channel = 36; }
	    @chan=@cfive;
	}
    }
    else
    {
	# 2 band device
	if ( $wifi_enable == 1 )
	{
	    $wifi2_hwmode="11a";
	    if ( $wifi2_channel < 36 ) { $wifi2_channel = 36; }
	    @chan=@cfive;
	}
	else
	{
	    if ( ! $wifi2_enable and $wifi3_enable and $wifi3_hwmode eq "11a" ) { $wifi2_hwmode = "11g"; }
	    if ( ! $wifi2_enable and $wifi3_enable and $wifi3_hwmode eq "11g" ) { $wifi2_hwmode = "11a"; }
	    if ( $wifi2_hwmode eq "11a" )
	    {
		if ( $wifi2_channel < 36 ) { $wifi2_channel = 36; }
	        @chan=@cfive;
	    }
	    else
	    {
		if ( $wifi2_channel > 14  ) { $wifi2_channel = 1; }
		@chan=@ctwo;
	    }
	}
    }

    print "<tr><th colspan=2>LAN Access Point</th></tr>";
    print "<tr><td>Enable</td>";
    print "<td><input type=checkbox name=wifi2_enable value=1";
    print " checked" if $wifi2_enable;
    print "></td></tr>\n";

    if ( $phycount > 1 ) {
	print "<tr><td>AP band</td>\n";
	print "<td><select name=wifi2_hwmode>\n";
	if ( ! $wifi_enable ) {
	    selopt("2GHz", "11g", $wifi2_hwmode);
	}
	selopt("5GHz", "11a", $wifi2_hwmode);
	print "</select></td></tr>\n";
    }
    else
    {
	push @hidden, "<input type=hidden name=wifi2_hwmode  value='$wifi2_hwmode'>";
    }

    print "<tr><td>SSID</td>\n";
    print "<td><input type=text size=15 name=wifi2_ssid value='$wifi2_ssid'></td></tr>\n";

    print "<tr><td>Channel</td>\n";
    print "<td><select name=wifi2_channel>\n";
    for  my $i (0 .. $#chan )
    {
	selopt($chan[$i], $chan[$i], $wifi2_channel);
    }

    print "</select></td></tr>\n";

    print "<tr><td>Encryption</td>\n";
    print "<td><select name=wifi2_encryption>\n";
	selopt("WPA2 PSK", "psk2", $wifi2_encryption);
	selopt("WPA PSK", "psk", $wifi2_encryption);
    print "</select></td></tr>\n";
    print "<tr><td>Password</td>\n";
    print "<td><input type=password size=15 name=wifi2_key value='$wifi2_key'>";
    print "</td></tr>\n";
}
else
{
    push @hidden, "<input type=hidden name=wifi2_enable     value='$wifi2_enable'>";
    push @hidden, "<input type=hidden name=wifi2_ssid       value='$wifi2_ssid'>";
    push @hidden, "<input type=hidden name=wifi2_key        value='$wifi2_key'>";
    push @hidden, "<input type=hidden name=wifi2_channel    value='$wifi2_channel'>";
    push @hidden, "<input type=hidden name=wifi2_encryption value='$wifi2_encryption'>"; 
    push @hidden, "<input type=hidden name=wifi2_hwmode     value='$wifi2_hwmode'>"; 
}

if(0) # disable for now
{
    print "<tr><td colspan=2><hr></td></tr>\n";
    print "<tr><td><nobr><i>Mesh Bridge</i></nobr></td>\n";
    print "<td><input type=checkbox name=olsrd_bridge value=1";
    print " checked" if $olsrd_bridge;
    print "></td></tr>\n";
}

print "</table></td>\n";

#
# WAN settings
#

print "<td valign=top width=33%><table width=100%>
<tr><th colspan=2>WAN</th></tr>
<tr>
<td width=50%>Protocol</td>\n";

print "<td><select name=wan_proto onChange='form.submit()'>\n";

selopt("Static", "static", $wan_proto);
selopt("DHCP", "dhcp", $wan_proto);
selopt("disabled", "disabled", $wan_proto);
print "</select></td>\n</tr>\n";

if($wan_proto eq "static")
{
    print "<tr><td><nobr>IP Address</nobr></td>\n";
    print "<td><input type=text size=15 name=wan_ip value='$wan_ip'></td></tr>\n";
    print "<tr><td>Netmask</td>\n";
    print "<td><input type=text size=15 name=wan_mask value='$wan_mask'></td></tr>\n";
    print "<tr><td>Gateway</td>\n";
    print "<td><input type=text size=15 name=wan_gw value='$wan_gw'></td></tr>\n";
}
else
{
    push @hidden, "<input type=hidden name=wan_ip value='$wan_ip'>";
    push @hidden, "<input type=hidden name=wan_mask value='$wan_mask'>";
    push @hidden, "<input type=hidden name=wan_gw value='$wan_gw'>";
}

print "<tr><td><nobr>DNS 1</nobr></td>\n";
print "<td><input type=text size=15 name=wan_dns1 value='$wan_dns1'></td></tr>\n";
print "<tr><td><nobr>DNS 2</nobr></td>\n";
print "<td><input type=text size=15 name=wan_dns2 value='$wan_dns2'></td></tr>\n";

print "<tr><td colspan=2><hr></td></tr>\n";
print "<tr><th colspan=2>Advanced WAN Access</th></tr>";
if ( $wan_proto ne "disabled" ) {
    print "<tr><td><nobr>Allow others to<br>use my WAN</td>\n";
    print "<td><input type=checkbox name=olsrd_gw value=1 title='Allow this node to provide internet access to other mesh users'";
    print " checked" if $olsrd_gw;
    print "></td></tr>\n";
} else {
    push @hidden, "<input type=hidden name=olsrd_gw value='0'>";
}
print "<tr><td><nobr>Prevent LAN devices<br>from accessing WAN</td>\n";
print "<td><input type=checkbox name=lan_dhcp_noroute value=1 title='Disable LAN devices to access the internet'";
print " checked" if ($lan_dhcp_noroute);
print "></td></tr>\n";

# WAN wifi Client

if ( ($phycount >  1 and (! $wifi_enable or  ! $wifi2_enable))
  or ($phycount == 1 and  ! $wifi_enable and ! $wifi2_enable )
 and ! $M39model )
{

    # Wifi Client shows as an option 

    # Determine hardware options and set band accordingly

    if ($phycount == 1)
    {
	$rc3 = system("iw phy phy0 info | grep -q '5180 MHz' > /dev/null");
	if ( $rc3 ) { $wifi3_hwmode="11g"; }
	else { $wifi3_hwmode="11a"; }
    }
    else
    {
	# 2 band device
	if ( $wifi_enable ) { $wifi3_hwmode="11a"; }
	else
	{
	    if ( $wifi2_hwmode eq "11g" and $wifi2_enable )
	    {
		$wifi3_hwmode = "11a";
	    }
	    if ( $wifi2_hwmode eq "11a" and $wifi2_enable )
	    {
		$wifi3_hwmode="11g";
	    }
	}
    }

    print "<tr><td colspan=2><hr></td></tr>\n";
    print "<tr><th colspan=2>WAN Wifi Client</th></tr>";
    print "<tr><td>Enable</td>";
    print "<td><input type=checkbox name=wifi3_enable value=1";
    print " checked" if $wifi3_enable;
    print "></td></tr>\n";

    if ( ! $wifi_enable and ! $wifi2_enable and $phycount > 1)
    {
	print "<tr><td>WAN Wifi Client band</td>\n";
	print "<td><select name=wifi3_hwmode>\n";
	selopt("2GHz", "11g", $wifi3_hwmode);
	selopt("5GHz", "11a", $wifi3_hwmode);
	print "</select></td></tr>\n";
    }
    else
    {
	push @hidden, "<input type=hidden name=wifi3_hwmode value='$wifi3_hwmode'>"; 
    }

#    for (my $i=0; $i<5; $i++)
#    {
#       @wan_ssids=`iw dev wlan0 scan passive | egrep  "SSID:\\s\\S+" | cut -f 2 -d\\ | sort -u`;
#       last if @wan_ssids;
#       sleep 1;
#    }

    print "<tr><td>SSID</td>\n";
    print "<td><input type=text name=wifi3_ssid size=15 value='$wifi3_ssid'>\n";
    print "</select></td></tr>\n";

    print "<tr><td>Password</td>\n";
    print "<td><input type=password size=15 name=wifi3_key value='$wifi3_key'>";
    print "</td></tr>\n";

}
else
{
    push @hidden, "<input type=hidden name=wifi3_enable     value='$wifi3_enable'>";
    push @hidden, "<input type=hidden name=wifi3_ssid       value='$wifi3_ssid'>";
    push @hidden, "<input type=hidden name=wifi3_key        value='$wifi3_key'>";
    push @hidden, "<input type=hidden name=wifi3_hwmode     value='$wifi3_hwmode'>"; 
}
# end WAN wifi Client

print "</table>\n</td></tr>\n";

print "</table>
</td></tr>
</table><br>
</td></tr>\n";

#
# Optional Settings
#

print "<tr><td align=center>\n";
print "<table cellpadding=5 border=0><tr><th colspan=4>Optional Settings</th></tr>";
print "<tr><td colspan=4><hr /></td></tr>";
print "<tr><td align=left>Latitude</td><td><input type=text name=latitude size=10 value='$lat' title='Latitude value (in decimal) (ie. 30.312354)' /></td>";
print "<td align='right' colspan='2'>";

print "<button type='button' id='findlocation' value='findloc' onClick='findLocation();'>Find Me!</button>&nbsp;";
print "<input type=submit name='button_updatelocation' value='Apply Location Settings' title='Immediately use these location settings'>";
print "&nbsp;<button type='button' id='hideshowmap' value='show' onClick='toggleMap(this);'>Show Map</button>&nbsp;";
if($pingOk)
{
    print "<input type='submit' name='button_uploaddata' value='Upload data to AREDN Servers' />&nbsp;";
} else {
    print "<button disabled type='button' title='Only available if this node has internet access'>Upload data to AREDN Servers</button>&nbsp;";
}

print "</td>\n";
print "<tr><td align=left>Longitude</td><td><input type=text name=longitude size=10 value='$lon' title='Longitude value (in decimal) (ie. -95.334454)' /></td>";
print "<td align=left>Grid Square</td><td align='left'><input type=text name=gridsquare maxlength=6 size=6 value='$gridsquare' title='Gridsquare value (ie. AB12cd)' /></td></tr>\n";
print "<tr><td colspan=4><div id='map' style='height: 200px; display: none;'></div></td></tr>";
print "<tr><td colspan=4><hr /></td></tr>";
print "<tr>
<td>Timezone</td>
<td><select name=time_zone_name tabindex=10>\n";

foreach my $tz (@$tz_db_names) {
    $name = $tz;
    $name =~ s/\_/ /g;
    selopt($name, $tz, $time_zone_name);
}

print "</select></td><td align=left>NTP Server</td><td><input type=text name=ntp_server size=20 value='$ntp_server'></td>";

print "</table></td></tr>";



print "</table>\n";

push @hidden, "<input type=hidden name=reload value=1>";
push @hidden, "<input type=hidden name=dtdlink_ip value='$dtdlink_ip'>";
foreach(@hidden) { print "$_\n" }

print "</form></center>\n";

show_debug_info();

if($debug)
{
    print "<br><b>config</b><br>\n";
    foreach(sort keys %cfg)
    {
	$tmp = $cfg{$_};
	$tmp =~ s/ /\(space\)/g;
	if($cfg{$_} eq "") { print "$_ = (null)<br>\n" }
	else               { print "$_ = $tmp<br>\n" }
    }
}

show_parse_errors();

page_footer();

print "</body>\n";
print "</html>\n";
