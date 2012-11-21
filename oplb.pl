#!/usr/bin/perl
#
# Open Proxies List Builder (OPLB)
# Author: Xavier Mertens <xavier(at)rootshell(dot)be>
# Copyright: GPLv3
#
use strict;
use Date::Parse;
use Getopt::Long;
use LWP::UserAgent;
use HTML::Entities;
use XML::XPath;
use XML::XPath::XMLParser;

# Check the presence of less usual Perl modules
eval "use WWW::ProxyChecker; 1" or die "Perl module WWW:ProxyChecker is not installed";
eval "use DBI; 1" or die "Perl module DBI not installed";

my $debug	= 0;
my $force	= 0;
my $dump	= 0;
my $help	= 0;
my $reliability = 75;
my $dbFile	= "oplb.db";
my $xroxyUrl	= "http://www.xroxy.com/rss";
my $xroxyUA	= "Xroxy-Aggregator PHP v0.3";
my $timeStamp	= 0;
my $lastChange	= 0;
my $eTag	= "";
my $ttl		= 3600;

# Arguments
my $result = GetOptions(
	"debug"		=> \$debug,
	"dump"		=> \$dump,
	"force"		=> \$force,
	"help"		=> \$help,
	"reliability=s"	=> \$reliability,
	"ttl=s"		=> \$ttl,
);

if ($help) {
	print <<__HELP__;
Usage: $0 [--debug] [--dump] [--force] [--help] [--reliability=percent] [--ttl=seconds]
Where:
--debug         : Produce verbose output
--dump          : Generate a list of reliable proxies (stdout)
--force         : Ignore TTL and force a check of the xroxy.com RSS feed
--reliability=x : Define minimum reliability for proxies (default: 75)
--ttl=x         : TTL for xroxy.com RSS feed update (default: 3600)
__HELP__
	exit 0;
}

# Parameters sanitization
(int($ttl) <= 0 || int($ttl) > 86400) && die "TTL is not valid ($ttl)";
(int($reliability) <= 0 || int($reliability) > 100) && die "Reliability is not valid ($reliability)";

if ($dump) {
	($debug) && print STDERR "+++ Dumping reliable proxies (>=" . $reliability . "%)\n";
	dumpProxies();
	exit 0;
}

readConfig();

if ((time() - $timeStamp) > $ttl || $force) {
	my $ua = LWP::UserAgent->new;
	$ua->timeout(30);
	$ua->agent($xroxyUA);
	my $timeString = scalar localtime($lastChange);
	$ua->default_header('If-Modified-Since' => "\"" . $timeString . "\"");
	$ua->default_header('If-None-Match:' => "\"" . $eTag . "\"");
	my $response = $ua->get($xroxyUrl);
	if ($response->is_success) {
		$lastChange = $response->header('Last-Modified');
		$eTag = $response->header('ETag');
		writeConfig($dbFile);
		parseXML($response->decoded_content);
	}
	else {
		($debug) &&  print STDERR "+++ Cannot fetch: " . $response->status_line . "\n";
	}
}
else {
	($debug) && print STDERR "+++ " . ($ttl + ($timeStamp - time())) . " seconds left to the next update.\n";
	checkProxies();
}
exit 0;

#
# Load the runtime parameters from SQL DB.
# Note: create an empty DB if needed (with default values)
#
sub readConfig {
	return unless defined($dbFile);
	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
		or die "Cannot connect to SQLite DB " . $dbFile;
	my $sth = $dbh->prepare("SELECT name FROM sqlite_master WHERE type='table' and name='configuration'");
	$sth->execute();
	my $data = $sth->fetch();
	if (!$data) { # Table 'configuration' does not exists, create it now
		($debug) && print "+++ Database not found, creating now!\n";
		$sth = $dbh->prepare("CREATE TABLE configuration (timestamp INTEGER,
								lastchange INTEGER,
								etag VARCHAR(256),
								ttl INTEGER)");
		$sth->execute() or die "Cannot create table 'configuration'";
		$sth = $dbh->prepare("CREATE TABLE proxies (id INTEGER,
								ip VARCHAR(15) PRIMARY KEY,
								port INTEGER,
								country VARCHAR(64),
								type VARCHAR(64),
								ssl VARCHAR(10),
								latency INTEGER,
								checkstotal INTEGER,
								checksok INTEGER,
								reliability INTEGER,
								lastcheck INTEGER)");
		$sth->execute() or die "Cannot create table 'proxies'";
		# Assign default configuration values
		$timeStamp = time();
		$lastChange = time();
		$eTag = "";
		$sth = $dbh->prepare("INSERT INTO configuration VALUES(" . $timeStamp . "," . $lastChange . ",\"" . $eTag . "\"," . $ttl . ")");
		$sth->execute() or die "Cannot save initial configuration";
	}
	else {
		$sth = $dbh->prepare("SELECT timestamp, lastchange, etag, ttl FROM configuration");
		$sth->execute() or die "Cannot read table 'confguratiion'";
		($timeStamp, $lastChange, $eTag, $ttl) = $sth->fetchrow_array();
	}
	($debug) && print STDERR "+++ Read configuration ($timeStamp, $lastChange, $eTag, $ttl)\n";
	return 0;
}

sub writeConfig {
	my $dbFile = shift;
	return unless defined($dbFile);
	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
		or die "Cannot connect to SQLite DB " . $dbFile;
	my $sth = $dbh->prepare("UPDATE configuration SET timestamp = " . time() . ", lastchange = " . str2time($lastChange) . ", etag = \"" . $eTag . "\"");
	$sth->execute() or die "Cannot save configuration";
	($debug) && print STDERR "+++ Saved configuration ($timeStamp, $lastChange, $eTag, $ttl)\n";
	return;
}

sub parseXML {
	my $xmlContent = shift;
	return unless defined($xmlContent);
	$xmlContent =~ s/\<\!\[CDATA\[//g;
	$xmlContent =~ s/\]\]\>//g;
	my $xml = XML::XPath->new(xml => $xmlContent);
	my $nodes = $xml->find('/rss/channel/item/description/proxy');
	foreach my $n ($nodes->get_nodelist) {
		saveProxy($n);
	}
}

sub saveProxy {
	my $n = shift;
	return unless defined $n;
	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
			or die "Cannot connect to SQLite DB " . $dbFile;
        my $sth = $dbh->prepare("SELECT ip FROM proxies WHERE ip='" . $n->find('ip')->string_value . "'");
        $sth->execute();
        my $data = $sth->fetch();
        if (!$data) {	# New proxy found...
		my $sth = $dbh->prepare("INSERT INTO proxies VALUES(" .
					$n->find('id')->string_value . ",\"" .
					$n->find('ip')->string_value . "\"," .
					$n->find('port')->string_value . ",\"" .
					$n->find('country')->string_value . "\",\"" .
					$n->find('type')->string_value . "\",\"" .
					$n->find('ssl')->string_value . "\"," .
					$n->find('latency')->string_value . ",0,0,0," .
					time() . ")");
		$sth->execute() or die "Cannot save proxy information";
		($debug) && print "+++ Saved new proxy: " . $n->find('ip')->string_value . "\n";
	}
	return;
}

sub checkProxies {
	my $pc = WWW::ProxyChecker->new(
                timeout => 10,
                max_kids => 25,
                check_sites => [ qw( http://pastebin.com http://www.google.com http://www.bing.com ) ],
                agent => 'Mozilla/5.0 (X11; U; Linux x86_64; en-US; rv:1.8.1.12)',
                debug => 0,
	);
	my $lastTimeStamp = time()-86400;
	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
			or die "Cannot connect to SQLite DB " . $dbFile;
	my $sth = $dbh->prepare("SELECT ip, port, checkstotal, checksok, lastcheck
				 FROM proxies
				 WHERE reliability < $reliability OR lastcheck < " . $lastTimeStamp .
				 " ORDER by lastcheck,reliability");
	$sth->execute();
	my @data;
	while (my @row = $sth->fetchrow_array()) {
		push @data, "http://" . $row[0] . ":" . $row[1];
	}
	$dbh->disconnect();
	foreach my $d (@data) {
		if ($d =~ /^http:\/\/(\S+):(\d+)/) {
			updateReliability($1, 0);
		}
	}
	for ( @{ $pc->check( \@data ) } ) {
		if ($_ =~ /^http:\/\/(\S+):(\d+)/) {
			updateReliability($1, 1);
		}
	}
	return;
}

sub updateReliability {
	my $ip = shift;
	my $status = shift;
	return unless defined($ip) and defined($status);

	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
			or die "Cannot connect to SQLite DB " . $dbFile;
	my $sth = $dbh->prepare("SELECT checkstotal, checksok FROM proxies WHERE ip = '" . $ip . "'");
	$sth->execute();
	my @row = $sth->fetchrow_array();
	my $total = ($status > 0) ? $row[0] : $row[0] +1;
	my $ok	 = ($status > 0) ? $row[1] + 1 : $row[1];
	my $reliability = int(($ok / $total) * 100);
	($debug && $status) && print "+++ $ip : Update reliability: $reliability%\n";
	my $sth = $dbh->prepare("UPDATE proxies SET checkstotal=" . $total . ",checksok=" . $ok . ",reliability=" . $reliability . ",lastcheck=" . time() . " WHERE ip = '" . $ip . "'");
	$sth->execute() or die "Cannot update proxy!";
	$dbh->disconnect();
}

sub dumpProxies {
	my $dbh = DBI->connect("dbi:SQLite:dbname=" . $dbFile)
		or die "Cannot connect to SQLite DB " . $dbFile;
	my $lowDate = time() - (3 * 86400);	# Back to last 3 days
	my $sth = $dbh->prepare("SELECT ip, port FROM proxies WHERE reliability >= $reliability AND type = \"Transparent\" AND lastcheck >= $lowDate");
	$sth->execute();
        while (my @row = $sth->fetchrow_array()) {
                print $row[0] . ":" . $row[1] . "\n";
        }
        $dbh->disconnect();
}
