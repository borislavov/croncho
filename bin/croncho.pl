#!/usr/bin/env perl

use strict;
use warnings;

my @configs = (
    '/etc/icn/croncho/croncho.conf',
    '/usr/local/icn/etc/croncho.conf',
    'croncho.conf',
    '../etc/croncho.conf'
    );


my $LOG;

use LWP::UserAgent;
use Schedule::Cron;
use Config::Simple;
use JSON;
use POSIX qw/strftime :sys_wait_h/;
use File::Copy;

sub read_config {
    my @configs = @_;
    my $config = {};
    my %days = (
	'Mon' => 1,
	'Tue' => 1,
	'Wed' => 1,
	'Thu' => 1,
	'Fri' => 1,
	'Sat' => 1,
	'Sun' => 1,
	'Monday' => 1,
	'Tuesday' => 1,
	'Wednesday' => 1,
	'Thursday' => 1,
	'Friday' => 1,
	'Saturday' => 1,
	'Sunday' => 1,
	'1' => 1,
	'2' => 1,
	'3' => 1,
	'4' => 1,
	'5' => 1,
	'6' => 1,
	'7' => 1,
	);

    my %server_types = (
	'1' => 'cPanel',
	'2' => 'ICN.bg Equipment',
	'3' => 'Custom',
	);

    for my $c (@configs) {
	if ( -f $c ) {
	    Config::Simple->import_from($c, $config);
	    last;
	}
    }

    if (!$server_types{$config->{server_type}}) {
	die "Cannot parse config. Invalid value for server_type: $config->{server_type}\n";
    }

    if (!$days{$config->{cron_fetch_day}}) {
	die "Cannot parse config. Invalid value for cron_fetch_day: $config->{cron_fetch_day}\n";
    }

    if ($config->{cron_fetch_time} !~ /^([0-9]{2}?):([0-9]{2}?)$/ ) {
	die "Cannot parse config. Invalid value for cron_fetch_time: |$config->{cron_fetch_time}|\n";
    }

    return $config;
};

sub open_log {
    my $config = shift;

    open($LOG, ">>:utf8", $config->{log_file}) || die "Cannot open log file: $config->{log_file}\n";
}

sub write_log {
    my $line = shift;

    my $date = strftime("%Y-%m-%d %H:%M:%S", localtime());

    print $LOG $date." ".$line."\n";
}


sub fetch_crons {
    my $config = shift;

    write_log("Fetching Cron jobs.");

    my $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 1 });

    $ua->timeout(10);

    my $response = $ua->get($config->{cron_repository});

    if ($response->is_success) {
	my $res_json = decode_json $response->decoded_content || undef;
	
	my $cron_file = $config->{cron_file};
	
	my $date = strftime("%Y-%m-%d-%H%M%S", localtime());

	if ( -f $cron_file ) {
	    write_log("Backing up Cron jobs file ".$cron_file."-".$date);
	    copy($cron_file, $cron_file."-".$date);
	}
	
	open(my $CRON, ">:utf8", $cron_file);

	if (!$CRON) {
	    write_log("Cannot open cron file for writting: ".$cron_file);
	    return -1;
	}

	write_log("Writing Cron jobs to file");

	foreach my $rule (@{$res_json->{crons}}) {
	    printf $CRON $rule->{date_time}." ".$rule->{job}."\n";
	}

	close($CRON);
    } else {
	write_log("Cannot fetch Cron jobs: ".$response->decoded_content);
	return -1;
    }

    return 1;
}

sub dispatcher {
    my $cmd = shift;
    write_log("Executing command: ".$cmd);
    my @cmd_out = `$cmd`;

    write_log("Command $cmd output: ".join(" ", @cmd_out));
}

sub main {
    my $config = read_config(@configs);

    if (!$config) {
	die "Cannot read config";
    }

    open_log($config);

    my $wday = strftime("%A", localtime());
    my $dow = strftime("%u", localtime());
    my $shday = strftime("%a", localtime());
    my $time = strftime("%H:%M", localtime());

    if ($config->{cron_fetch_day} eq $wday ||
	$config->{cron_fetch_day} eq $dow ||
	$config->{cron_fetch_day} eq $shday) {

	if ($config->{cron_fetch_time} eq $time) {

	    my $ret = fetch_crons($config);

	    if (!$ret) {
		close($LOG);
		die;
	    }
	}
    }
    
    my $cron = new Schedule::Cron(\&dispatcher, { dispatcher => \&dispatcher});
    $cron->load_crontab($config->{cron_file});

    my @entries = $cron->list_entries();

    open(my $PID, "<", $config->{cron_pid_file});

    if ($PID) {
	my $pid = <$PID>;
	close($PID);

	write_log("Terminating Cron Scheduler");

	kill 'KILL', $pid;
	my $kid;

	do {
	    $kid = waitpid($pid,WNOHANG);
	} while $kid > 0;

	write_log("Starting Cron scheduler");
	$cron->run(detach=>1, pid_file => $config->{cron_pid_file});
    } else  {
	write_log("Starting Cron scheduler");
	$cron->run(detach=>1, pid_file => $config->{cron_pid_file});
    }

    close($LOG);
}

main();
