#!/usr/bin/perl
##########################################################################
# Pandora Server. SNMP Console
##########################################################################
# Copyright (c) 2004-2006 Sancho Lerena, slerena@gmail.com
# Copyright (c) 2005-2006 Artica Soluciones Tecnologicas S.L
#
#This program is free software; you can redistribute it and/or
#modify it under the terms of the GNU General Public License
#as published by the Free Software Foundation; either version 2
#of the License, or (at your option) any later version.
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#You should have received a copy of the GNU General Public License
#along with this program; if not, write to the Free Software
#Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##########################################################################

# Includes list
use strict;
use warnings;

use Date::Manip;                	# Needed to manipulate DateTime formats of input, output and compare
use Time::Local;                	# DateTime basic manipulation
use Time::HiRes;			# For high precission timedate functions (Net::Ping)

# Pandora Modules
use pandora_config;
use pandora_tools;
use pandora_db;

# FLUSH in each IO (only for debug, very slooow)
# ENABLED in DEBUGMODE
# DISABLE FOR PRODUCTION
$| = 1;

my %pa_config;

# Inicio del bucle principal de programa
pandora_init(\%pa_config,"Pandora SNMP Console");
# Read config file for Global variables
pandora_loadconfig (\%pa_config,2);

# Audit server starting
pandora_audit (\%pa_config, "Pandora Server SNMP Console Daemon starting", "SYSTEM", "System");

# Daemonize of configured
if ( $pa_config{"daemon"} eq "1" ) {
	print " [*] Backgrounding...\n";
	&daemonize;
}

pandora_snmptrapd (\%pa_config);


##########################################################################
## SUB pandora_snmptrapd
## Pandora SNMP Trap console/daemon subsystem
##########################################################################

sub pandora_snmptrapd {
	my $pa_config = $_[0];
	my $snmp_logfile = $pa_config->{'pandora_path'}."/log/snmptrapd.log";
	my $logfile_size; # Size of logfile, use for calculating index file
	my @array;
	my $datos;
	my $timestamp;
	my $source;
	my $oid;
	my $type;
	my $type_desc;
	my $value;
	my $custom_oid;
	my $custom_type;
	my $custom_value;
	my $sql_insert;
	my @index_data;

	if ( ! -e $snmp_logfile) { # Wait until a snmplogfile exists
		sleep 5; 
	}
	open (SNMPLOGFILE, $snmp_logfile);
	print " [*] SNMP Console enabled \n";
	$index_data[0]=0;
	$index_data[1]=0;
	# Check for index file
	if ( -e  $snmp_logfile.".index" ){
		open SNMPLOGFILE_INDEX, $snmp_logfile.".index";
		$datos = <SNMPLOGFILE_INDEX>;
		close SNMPLOGFILE_INDEX;
		@index_data = split(/\s+/,$datos);
		# $index_data[0] is the last line readed
		# $index_data[1] is the size of file (use for calculate new files or reset logfiles
	}
	$logfile_size = (stat($snmp_logfile))[7];

	if ($logfile_size < $index_data[1]){ # Log size smaller last time we read it -> new one
		unlink ($snmp_logfile.".index");
		$index_data[0]=0;
		$index_data[1]=0;
		logger ($pa_config,"New SNMP logfile detected, resetting index",1);
	}

	if (($index_data[1] <= $logfile_size) && ($index_data[0] > 0)){ 
		# Skip already processed records
		for ($value=0;$value < $index_data[0];$value++){
			$datos = readline SNMPLOGFILE;
		}
	}
	# open database, only ONCE. We pass reference to DBI handler ($dbh) to all subprocess
	my $dbh = DBI->connect("DBI:mysql:pandora:$pa_config->{'dbhost'}:3306",$pa_config->{'dbuser'}, $pa_config->{'dbpass'},	{ RaiseError => 1, AutoCommit => 1 });

	# Main loop for reading file
	while ( 1 ){
		while ($datos = <SNMPLOGFILE>) {
			$index_data[0]++;
			$index_data[1]=(stat($snmp_logfile))[7];
			open SNMPLOGFILE_INDEX, ">".$snmp_logfile.".index";
			print SNMPLOGFILE_INDEX $index_data[0]," ",$index_data[1];
			close SNMPLOGFILE_INDEX;

			#print "DEBUG $datos \n";
			if (($datos !~ m/NET-SNMP/) && ($datos =~ m/\[\*\*\]/)) { # SKIP Headers
				@array = split(/\[\*\*\]/, $datos);
				$timestamp = $array[0]." ".$array[1];
				$source = $array[2];
				$oid = $array[3];
				$type = $array[4];
				$type_desc = $array[5];
				$value = limpia_cadena($array[6]);
				if ($type == 6){ # Custom OID type
					$datos = $array[7];
					if ($datos !~ m/STRING/) { # No string datatype, marked with " chars
						$datos =~ m/([0-9\.]*)\s\=\s([A-Za-z0-9]*)\:\s(.+)/;
						$custom_oid = $1;
						$custom_type = $2;
						$custom_value = limpia_cadena($3);
					} else { # String type
						if ($datos =~ m/([0-9\.]*)\s\=\s([A-Za-z0-9]*)\:\s\"(.+)\"/){
							$custom_oid = $1;
							$custom_type = $2;
							$custom_value = limpia_cadena($3);
						}
					}
				} else { # not custom OID type, deleting old values in these vars
					$custom_oid="";
					$custom_type="";
					$custom_value="type_desc";
				}
				$sql_insert = "insert into ttrap (timestamp, source, oid, type, value, oid_custom, value_custom,  type_custom) values ('$timestamp', '$source', '$oid', $type, '$value', '$custom_oid', '$custom_value', '$custom_type')";
				logger ($pa_config,"Received SNMP Trap from $source",2);
				eval {
					$dbh->do($sql_insert) || logger ($pa_config, "Cannot write to database while updating SNMP Trap data (error in INSERT)",0);
					# Evaluate TRAP Alerts for this trap
					calcula_alerta_snmp($pa_config, $source,$oid,$custom_value,$timestamp,$dbh);
				};
				if ($@) {
					logger ($pa_config, "[ERROR] Cannot access to database while updating SNMP Trap data",0);
					logger ($pa_config, "[ERROR] SQL Errorcode: $@",2);
				}
			}
		}
		sleep ($pa_config{'server_threshold'});
		pandora_serverkeepaliver($pa_config,2,$dbh);
	}
	$dbh->disconnect();
}


##########################################################################
## SUB calcula_alerta_snmp($source,$oid,$custom_value,$timestamp);
## Given an SNMP Trap received with this data, execute Alert or not
##########################################################################

sub calcula_alerta_snmp {
	# Parameters passed as arguments
	my $pa_config = $_[0];
        my $trap_agente = $_[1];
        my $trap_oid = $_[2];
        my $trap_custom_value = $_[3];
	my $timestamp = $_[4];
	my $dbh = $_[5];
	my $alert_fired = 0;
	
    	my $query_idag = "select * from talert_snmp";
    	my $s_idag = $dbh->prepare($query_idag);
        $s_idag ->execute;
        my @data;
	# Read all alerts and apply to this incoming trap 
	if ($s_idag->rows != 0) {
		while (@data = $s_idag->fetchrow_array()) {
			$alert_fired = 0;		
			my $id_as = $data[0];
			my $id_alert = $data[1];
			my $field1 = $data[2];
			my $field2 = $data[3];
			my $field3 = $data[4];
			my $description = $data[5];
			my $alert_type = $data[6];
			my $agent = $data[7];
			my $custom_oid = $data[8];
			my $oid = $data[9];
			my $time_threshold = $data[10];
			my $times_fired = $data[11];
			my $last_fired = $data[12]; # The real fired alarms
			my $max_alerts = $data[13];
			my $min_alerts = $data[14]; # The real triggered alarms (not really fired, only triggered)
			my $internal_counter = $data[15];
			my $alert_data = "";
			if ($alert_type == 0){ # type 0 is OID only
				if ( $trap_oid =~ m/$oid/i ){
					$alert_fired = 1;
					$alert_data = "SNMP/OID:".$oid;
					logger ($pa_config,"SNMP Alert debug (OID) MATCHED",10);
				}
			} elsif ($alert_type == 1){ # type 1 is custom value 
				logger ($pa_config,"SNMP Alert debug (Custom) $custom_oid / $trap_custom_value",10);
				if ( $trap_custom_value =~ m/$custom_oid/i ){
					$alert_fired = 1;
					$alert_data = "SNMP/VALUE:".$custom_oid;
					logger ($pa_config,"SNMP Alert debug (Custom) MATCHED",10);
				}
			} else { # type 2 is agent IP
				if ($trap_agente =~ m/$agent/i ){
					$alert_fired = 1;
					$alert_data = "SNMP/SOURCE:".$agent;
					logger ($pa_config,"SNMP Alert debug (SOURCE) MATCHED",10);
				}
			}

			if ($alert_fired == 1){ # Exists condition to fire alarm.
				# Verify if under time_threshold
				my $fecha_ultima_alerta = ParseDate($last_fired);
				my $fecha_actual = ParseDate( $timestamp );
				my $ahora_mysql = &UnixDate("today","%Y-%m-%d %H:%M:%S"); # If we need to update MYSQL last_fired will use $ahora_mysql
				my $err; my $flag;
				my $fecha_limite = DateCalc($fecha_ultima_alerta,"+ $time_threshold seconds",\$err);
				# verify if upper min alerts
				# Verify if under min alerts
				$flag = Date_Cmp($fecha_actual,$fecha_limite);
				if ( $flag >= 0 ) { # Out limits !, reset $times_fired, but do not write to
						    # database until a real alarm was fired
					$times_fired = 0;
					$internal_counter=0;
					logger ($pa_config,"SNMP Alarm out of timethreshold limits",10);
				}
				# We are between limits marked by time_threshold or running a new time-alarm-interval 
				# Caution: MIN Limit is related to triggered (in time-threshold limit) alerts
				# but MAX limit is related to executed alerts, not only triggered. Because an alarm to be
				# executed could be triggered X (min value) times to be executed.
				if (($internal_counter+1 >= $min_alerts) && ($times_fired+1 <= $max_alerts)){
					# The new alert is between last valid time + threshold and between max/min limit to alerts in this gap of time.
					$times_fired++;
					$internal_counter++;
					# ---------> EXECUTE ALERT <---------------
					logger($pa_config,"Executing SNMP Trap alert for $agent - $alert_data",2);
					execute_alert ($pa_config, $id_alert, $field1, $field2, $field3, $trap_agente, $timestamp, $alert_data, "", "", $dbh);
					# Now update the new value for times_fired, alert_fired, internal_counter and last_fired for this alert.
					my $query_idag2 = "update talert_snmp set times_fired = $times_fired, last_fired = '$ahora_mysql', internal_counter = $internal_counter where id_as = $id_as ";
					$dbh->do($query_idag2);

					# Now find record for trap and update "fired" status... 
					# Due DBI doesnt return ID of a new inserted item, we now need to find ourselves 
					# this is a crap :(

					my $query_idag3 = "update ttrap set alerted = 1 where timestamp = '$timestamp' and source = '$trap_agente'";
					$dbh->do($query_idag3);

				} else { # Alert is in valid timegap but has too many alerts or too many little
					$internal_counter++;
					if ($internal_counter < $min_alerts){
						# Now update the new value for times_fired & last_fired if we are below min limit for triggering this alert
						my $query_idag = "update talert_snmp set internal_counter = $internal_counter, times_fired = $times_fired, last_fired = '$ahora_mysql' where id_as = $id_as ";
						$dbh->do($query_idag);
						logger ($pa_config, "SNMP Alarm not fired because is below min limit",8);
					} else { # Too many alerts fired (upper limit)
						my $query_idag = "update talert_snmp set times_fired=$times_fired, internal_counter = $internal_counter where id_as = $id_as ";
						$dbh->do($query_idag);
						logger ($pa_config, "SNMP Alarm not fired because is above max limit",8);
					}
				}
			}
		} # While
	} # if
	$s_idag->finish();
}
