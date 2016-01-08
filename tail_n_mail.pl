#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Tail one or more files, mail the new stuff to one or more emails
## Developed at End Point Corporation by:
## Greg Sabino Mullane <greg@endpoint.com>
## Selena Deckelmann <selena@chesnok.com>
## See more contributors in the 'Changes' file
## BSD licensed
## For full documentation, please see: http://bucardo.org/wiki/Tail_n_mail

##
## Quick usage:
## Run: tail tail_n_mail > tail_n_mail.config
## Edit tail_n_mail.config in your favorite editor
## Run: perl tail_n_mail tail_n_mail.config
## Once working, put the above into a cron job

use 5.10.1;
use strict;
use warnings;
use Data::Dumper   qw( Dumper              );
use Getopt::Long   qw( GetOptions          );
use File::Temp     qw( tempfile            );
use File::Basename qw( dirname             );
use POSIX          qw( strftime localeconv );

our $VERSION = '1.27.0';

## Default message subject if not set elsewhere. Keywords replaced: FILE HOST NUMBER UNIQUE
my $DEFAULT_SUBJECT= 'Results for FILE on host: HOST UNIQUE : NUMBER';

## Do some really simple line wrapping for super-long lines
my $WRAPLIMIT = 990;

## Set defaults for all the options, then read them in from command line
my %arg = (
## Show a help screen
              help             => 0,
## Show version and exit
              version          => 0,
## Do everything except send mail and update files
              dryrun           => 0,
## Verbose mode
              verbose          => 0,
## Be as quiet as possible
              quiet            => 0,
## Heavy debugging output
              debug            => 0,
## Reset the marker of the log file to the current position
              reset            => 0,
## Rewind to a certain position inside the log file
              rewind           => 0,
## Which mail mode to use: can be sendmail or smtp
              mailmode         => 'sendmail',
## Use SMTP mode (sets mailmode to smtp)
              smtp             => 0,
## Location of the sendmail program. Expects to be able to use a -f argument.
              mailcom          => '/usr/sbin/sendmail',
## Mail options when using SMTP mode:
              mailserver       => 'example.com',
              mailuser         => 'example',
              mailpass         => 'example',
              mailport         => 465,
## Are we parsing Postgres logs?
              pgmode           => 1,
## What type of Postgres log we are parsing. Can be log, csv, or syslog
              pglog            => 'pg',
## What is Postgres's log_line_prefix
              log_line_prefix  => '',
## Maximum size of a statement before we truncate it.
              statement_size   => 1000,
## How to sort the output. Options are 'count' and 'date'
              sortby           => 'count',
## What type of file is this? Options are 'normal', 'duration', and 'tempfile'
              type             => 'normal',
## Allow the offset to be changed on the fly
              offset           => -1,
## Set the minimum duration
              duration         => -1,
## Set the minimum temp file size
              tempfile         => -1,
## Allow override of the log file to check
              file             => [],
## Strip out SQLSTATE codes from the FATAL and ERROR messages
              sqlstate         => 0,
## Do not send email
              nomail           => 0,
## Flatten similar queries into a canonical form
              flatten          => 1,
## Hide the flattened version if there is only a single entry
              hideflatten      => 1,
## Move around in time for debugging
              timewarp         => 0,
## Show which line number problems are found on. Should be disabled for large/frequent reports
              find_line_number => 1,
## The maximum bytes we will go back and check per file
              maxsize          => 80_000_000,
## Only show X number of matches
              showonly         => 0,
## Send an email even if 0 matches were found
              mailzero         => 0,
## Append a signature to the end of mailed messages
              mailsig          => [],
## Perform some final prettification of queries
              pretty_query     => 1,
## Set the minimum number of matching duration entries that we care about
              duration_limit   => 0,
## Set the minimum number of matching tempfile entries that we care about
              tempfile_limit   => 0,
## The thousands separator for formatting numbers.
              tsep             => undef,
## Whether to turn off thousands separator in subject lines (mailman bug workaround)
              tsepnosub        => 0,
## The maximum file size before we split things up before mailing
              maxemailsize     => 10_000_000, ## bytes
## Do we skip lines that we cannot parse (e.g. rsync errors)?
              skip_non_parsed => 0,
);

## Quick check for help items
for my $item (@ARGV) {
    if ($item =~ /^-+\?$/) {
        help();
    }
}

my $result = GetOptions
 (
     \%arg,
   'verbose',
   'quiet',
   'debug',
   'dryrun|dry-run',
   'help',
   'nomail',
   'reset',
   'rewind=i',
   'version',
   'offset=i',
   'duration=i',
   'tempfile=i',
   'file=s@',
   'sqlstate',
   'type=s',
   'flatten!',
   'hideflatten!',
   'timewarp=i',
   'pgmode=s',
   'pglog=s',
   'log_line_prefix=s',
   'maxsize=i',
   'sortby=s',
   'showonly=i',
   'mailmode=s',
   'mailcom=s',
   'mailserver=s',
   'mailuser=s',
   'mailpass=s',
   'mailport=s',
   'mailzero',
   'mailsig=s@',
   'smtp',
   'tsep=s',
   'tsepnosub',
   'nolastfile',
   'pretty_query',
   'duration_limit=i',
   'tempfile_limit=i',
   'statement_size=i',
   'tailnmailrc=s',
   'no-tailnmailrc',
   'maxemailsize=i',
   'skip_non_parsed',
  ) or help();
++$arg{verbose} if $arg{debug};

if ($arg{version}) {
    print "$0 version $VERSION\n";
    exit 0;
}

sub help {
    print "Usage: $0 configfile [options]\n";
    print "For full documentation, please visit:\n";
    print "http://bucardo.org/wiki/Tail_n_mail\n";
    exit 0;
}
$arg{help} and help();

$arg{smtp} and $arg{mailmode} = 'smtp';

## First option is always the config file, which must exist.
my $configfile = shift or die qq{Usage: $0 configfile\n};

## If the file has the name 'duration' in it, or we have set the duration parameter,
## switch to that type as the default
if ($configfile =~ /duration/i or $arg{duration} > 0) {
    $arg{type} = 'duration';
}

## If the file has the name 'tempfile' in it, or we have set the tempfile parameter,
## switch to that type as the default
if ($configfile =~ /tempfile/i or $arg{tempfile} > 0) {
    $arg{type} = 'tempfile';
}

## Quick expansion of leading tildes for the file argument
for (@{ $arg{file} }) {
    s{^~/?}{$ENV{HOME}/};
}

## Save away our hostname
my $hostname = qx{hostname};
chomp $hostname;

## Global option variables
my (%opt, %itemcomment);

## Read in any rc files
parse_rc_files();
## Read in and parse the config file
parse_config_file();
## Read in any inherited config files and merge their information in
parse_inherited_files();

## Allow whitespace in configurable items by wrapping in double quotes
## Here, we remove them
for my $k (keys %opt) {
    $opt{$k} =~ s/^"(.+)"$/$1/;
}

## Figure out the log_line_prefix, then create a regex for it
my $default_llp = '%t [%p]';

my $llp = $arg{log_line_prefix}
    || $opt{log_line_prefix}
    ||($arg{pglog} eq 'syslog' ? '' : $default_llp);

## Remove any quotes around it
$llp =~ s{^'(.+)'$}{$1};

## Save a copy for later on
my $original_llp = $llp;

## Process the log_line_prefix and change it into a regex
my ($havetime,$havepid) = (0,0);

## Escape certain things that may confuse the regex parser
$llp =~ s/([\-\[\]\(\)])/\\$1/g;

## This assumes timestamp comes before the pid!
$llp =~ s/%t/(\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d \\w\\w\\w\\w?)/ and $havetime=1;
$llp =~ s/%m/(\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d\\.\\d+ \\w\\w\\w\\w?)/ and $havetime=1;
if (!$havetime and $arg{pglog} ne 'syslog') {
    $llp = "()$llp";
}
$llp =~ s/%p/(\\d+)/ and $havepid = 1;
$llp =~ s/%c/(\\S+)/ and $havepid = 1;
if (!$havepid and $arg{pglog} ne 'syslog') {
    $llp = "()$llp";
}
$llp =~ s/%l/\\d+/;
$llp =~ s/%u/[\\[\\w\\-\\.\\]]*/;
$llp =~ s/%d/[\\[\\w\\-\\.\\]]*/;
$llp =~ s/%r/\\S*/;
$llp =~ s/%h/\\S*/;
$llp =~ s/%a/\\S*/;
$llp =~ s/%e/[0-9A-Z]{5}/;
$llp =~ s/%q//;

if ($arg{pglog} eq 'syslog') {
    ## Syslog is a little more specific
    ## It's not standard, but usually standard 'enough' to build a working regex
    ## Add in timestamp, host, process name, pid, and number
    ## This will probably break if your log_line_prefix has a timestamp,
    ## but why would you do that if using syslog? :)
    $llp = "(.+?\\d) \\S+ \\S+\\[(\\d+)\\]: \\[\\d+\\-\\d+\\] $llp";
    $havetime = $havepid = 1;
}
my $pgpidre = qr{^($llp)(.*)};

$arg{verbose} and $arg{pgmode} and warn "  Log line prefix regex: $pgpidre\n";

## And a separate one for cluster-wide notices
my $llp2 = $original_llp;

## Items set clusterwide: %t %m %p
$llp2 =~ s/([\-\[\]])/\\$1/g;
$llp2 =~ s/%t/\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d \\w\\w\\w\\w?/;
$llp2 =~ s/%m/\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d\\.\\d+ \\w\\w\\w\\w?/;
$llp2 =~ s/%p/\\d+/;
## Items not set clusterwide: %u %d %r %h %i %c %l %s %v %x
for my $char (qw/ u d r h i c l s v x/) {
    $llp2 =~ s/%$char//g;
}
my $pgpidre2 = qr{^$llp2};

$arg{verbose} and $arg{pgmode} and warn "  Log line prefix regex2: $pgpidre2\n";

## And one more for things that throw out everything except the timestamp
## May not work on against all log_line_prefixes
my $llp3 = $original_llp;

## Strip out everything past the first setting
$llp3 =~ s/(.*?%\w).+/$1/;
## Convert %t and %m
$llp3 =~ s/%t/\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d \\w\\w\\w\\w?/;
$llp3 =~ s/%m/\\d\\d\\d\\d\-\\d\\d\-\\d\\d \\d\\d:\\d\\d:\\d\\d\\.\\d+ \\w\\w\\w\\w?/;
## Remove any other escapes
$llp3 =~ s/%\w//g;
my $pgpidre3 = qr{^$llp3};

$arg{verbose} and $arg{pgmode} and warn "  Log line prefix regex3: $pgpidre3\n";

## Keep track of changes to know if we need to rewrite the config file or not
my $changes = 0;

## Global regex: may change per file
my ($exclude, $include, $exclude_prefix, $exclude_non_parsed);

## Note if we bumped into maxsize when trying to read a file
my (%toolarge);

# Actual matching strings are stored here
my %find;

## Keep track of which entries are similar to the ones we've seen before for possible flattening
my %similar;

## Map filenames to "A", "B", etc. for clean output of multiple matches
my %fab;

## Are we viewing the older version of the file because it was rotated?
my $rotatedfile = 0;

## Did we handle more than one file this round?
my $multifile = 0;

## Total matches across all files
$opt{grand_total} = 0;

## For help in sorting later on
my (%fileorder, $filenum);

## Generic globals
my ($string,$time,$csv);

## If they requested no lastfile, remove it now
if ($arg{nolastfile}) {
    delete $opt{lastfile};
}

## If they want a mail signature, open the file(s) and read it in now
if (defined $arg{mailsig}->[0]) {
    ## Combine all files in order into a single string
    my $sigstring = '';
    my $fh;
    for my $sigfile (@{$arg{mailsig}}) {
        $sigfile =~ s{^~/?}{$ENV{HOME}/};
        if (! open $fh, '<', $sigfile) {
            warn qq{Could not open signature file "$sigfile": $!\n};
            exit 1;
        }
        { local $/; $sigstring .= <$fh>; }
        close $fh or warn qq{Could not close "$sigfile": $!\n};
    }
    $arg{mailsignature} = $sigstring;
}

## Parse each file returned by pick_log_file until we start looping
my $last_logfile = '';
my @files_parsed;
my $filenumber = 0;
my $fileinfo = $opt{file}[$filenumber];

{

    ## Generate the next log file to parse
    my $logfile = pick_log_file($fileinfo);
    
    ## If undefined or same as last time, we are done with this file
    if (! defined $logfile or $logfile eq $last_logfile) {
        ## Grab the next extry
        $fileinfo = $opt{file}[++$filenumber];
        ## No more file? We are done!
        last if ! defined $fileinfo;
        # Otherwise, loop back with the new fileinfo
        redo;
    }

    $arg{debug} and warn " Parsing file: $logfile\n";

    my $count = parse_file($logfile, $fileinfo);
    if ($count >= 0) {
        push @files_parsed => [$logfile, $count];
        $fileorder{$logfile} = ++$filenum;
    }

    $last_logfile = $logfile;

    redo;
}

## We're done parsing the message, send an email if needed
process_report() if $opt{grand_total} or $arg{mailzero} or $opt{mailzero};
final_cleanup();

exit 0;


sub pick_log_file {

    ## Figure out which files we need to parse
    ## Sole argument is a hashref of file information:
    ##   name: logfile to open
    ##   original: original name
    ##   lastfile: we scanned last time this ran. May be an empty string or not exist

    my $info = shift;

    my $name = $info->{name} or die 'No name for the file found!';
    my $orig = $info->{original} or die 'No original file found!';
    my $lastfile = $info->{lastfile} || '';

    ## Basic flow:
    ## Start with "last" (and apply offset to it)
    ## Then walk forward until we hit the most recent one

    ## Handle the LATEST case right away
    if ($orig =~ s{([^/\\]*)LATEST([^/\\]*)$}{}o) {

        my ($prefix,$postfix) = ($1,$2);

        ## At this point, the lastfile has already been handled
        ## We need all files newer than that one, in order, until we run out

        ## If we don't have the list already, build it now
        if (! exists $opt{middle_filenames}) {

            my $dir = $orig;
            $dir =~ s{/\z}{};
            -d $dir or die qq{Cannot open $dir: not a directory!\n};
            opendir my $dh, $dir or die qq{Could not opendir "$dir": $!\n};

            ## We need the modification time of the lastfile
            my $lastfiletime = defined $lastfile ? -M $lastfile : 0;

            my %fileq;
            while (my $file = readdir($dh)) {
                my $fname = "$dir/$file";
                my $modtime = -M $fname;
                ## Skip if not a normal file
                next if ! -f _;
                if (length $prefix or length $postfix) {
                    next if $file !~ /\A\Q$prefix\E.*\Q$postfix\E\z/o;
                }
                ## Skip if it's older than the lastfile
                next if $lastfiletime and $modtime > $lastfiletime;
                $fileq{$modtime}{$fname} = 1;
            }
            closedir $dh or warn qq{Could not closedir "$dir": $!\n};

          TF: for my $time (sort { $a <=> $b } keys %fileq) {
                for my $file (sort keys %{$fileq{$time}}) {
                    push @{$opt{middle_filenames}} => $file;
                    ## If we don't have a lastfile, we simply use the most recent file
                    ## and throw away the rest
                    last TF if ! $lastfiletime;
                }
            }
        }

        ## Return the next file, or undef when we run out
        my $nextfile = pop @{ $opt{middle_filenames} };
        ## If we are done, remove this temp hash
        if (! defined $nextfile) {
            delete $opt{middle_filenames};
        }
        return $nextfile;

    } ## end of LATEST time travel

    ## No lastfile makes it easy
    return $name if ! $lastfile;

    ## If we haven't processed the lastfile, do that one first
    return $lastfile if ! exists $find{$lastfile};

    ## If the last is the same as the current, return the name
    return $name if $lastfile eq $name;

    ## We've processed the last file, are there any files in between the two?
    ## POSIX-based time travel
    if ($orig =~ /%/) {

        ## Build the list if we don't have it yet
        if (! exists $opt{middle_filenames}) {

            ## We're going to walk backwards, 30 minutes at a time, and gather up
            ## all files between "now" and the "last"
            my $timerewind = 60*30; ## 30 minutes
            my $maxloops = 24*2 * 7 * 60; ## max of 60 days
            my $bail = 0;
            my %seenfile;
            my $lastchecked = '';
          BACKINTIME: {

                my @ltime = localtime(time - $timerewind);
                my $newfile = strftime($orig, @ltime);
                if ($newfile ne $lastchecked) {
                    last if $newfile eq $lastfile;
                    $arg{debug} and warn "Checking for file $newfile (last was $lastfile)\n";
                    if (! exists $seenfile{$newfile}) {
                        $seenfile{$newfile} = 1;
                        push @{$opt{middle_filenames}} => $newfile;
                    }
                    $lastchecked = $newfile;
                }

                $timerewind += 60*30;
                ++$bail > $maxloops and die "Too many loops ($bail): bailing\n";
                redo;
            }

        }

        ## If the above loop found nothing, return the current name
        if (! exists $opt{middle_filenames}) {
            return $name;
        }

        ## Otherwise, pull it off the list until there is nothing left
        my $nextfile = pop @{ $opt{middle_filenames} };
        ## If we are done, remove this temp hash
        if (! defined $nextfile) {
            delete $opt{middle_filenames};
        }
        return $nextfile;
    }

    ## Just return the current file
    return $name;

} ## end of pick_log_file


sub parse_rc_files {

    ## Read in global settings from rc files

    my $file;
    if (! $arg{'no-tailnmailrc'}) {
        if ($arg{tailnmailrc}) {
            -e $arg{tailnmailrc} or die "Could not find the file ", $arg{tailnmailrc}, "\n";
            $file = $arg{tailnmailrc};
        }
        elsif (-e '.tailnmailrc') {
            $file = '.tailnmailrc';
        }
        elsif (exists $ENV{HOME} and -e "$ENV{HOME}/.tailnmailrc") {
            $file = "$ENV{HOME}/.tailnmailrc";
        }
        elsif (-e '/etc/tailnmailrc') {
            $file = '/etc/tailnmailrc';
        }
    }
    if (defined $file) {
        open my $rc, '<', $file or die qq{Could not open "$file": $!\n};
        while (<$rc>) {
            next if /^\s*#/;
            next if ! /^\s*([\w\_\-]+)\s*[=:]\s*(.+?)\s*$/o;
            my ($name,$value) = (lc $1,$2);
            ## Special case for leading and trailing whitespace
            $value =~ s/^"(.+)"$/$1/;
            $opt{$name} = $value;
            $arg{$name} = $value;
            ## If we are disabled, simply exit quietly
            if ($name eq 'disable' and $value) {
                exit 0;
            }
            if ($name eq 'maxsize') {
                $arg{maxsize} = $value;
            }
            if ($name eq 'duration_limit') {
                $arg{duration_limit} = $value;
            }
            if ($name eq 'tempfile_limit') {
                $arg{tempfile_limit} = $value;
            }
        }
        close $rc or die;
    }

    return;

} ## end of parse_rc_files


sub parse_config_file {

    ## Read in a configuration file and populate the global %opt

    ## Are we in the standard non-user comments at the top of the file?
    my $in_standard_comments = 1;

    ## Temporarily store user comments until we know where to put them
    my (@comment);

    ## Keep track of duplicate lines: ignore any but the first
    my %seenit;

    ## Store locally so we can easily populate %opt at the end
    my %localopt;

    open my $c, '<', $configfile or die qq{Could not open "$configfile": $!\n};
    $arg{debug} and warn qq{Opened config file "$configfile"\n};
    while (<$c>) {

        ## If we are at the top of the file, don't store standard comments
        if ($in_standard_comments) {
            next if /^## Config file for/;
            next if /^## This file is automatically updated/;
            next if /^## Last updated:/;
            next if /^\s*$/;
            ## Once we reach the first non-comment, non-whitespace line,
            ## treat it as a normal line
            $in_standard_comments = 0;
        }

        ## Found a user comment; store it away until we have context for it
        if (/^\s*#/) {
            push @comment => $_;
            next;
        }

        ## If the exact same line shows up more than once ignore it.
        ## Failing to do so will confuse the comment hash
        if (/^[\w]/ and $seenit{$_}++) {
            warn "Duplicate entry will be ignored at line $.: $_\n";
            next;
        }

        ## A non-comment after one or more comments allows us to map them to each other
        if (@comment and m{^([\w\_\-]+):}) {
            my $keyword = $1;
            my $line = $_;
            chomp $line;
            for my $c (@comment) {
                ## We store as both the keyword and the entire line
                push @{$itemcomment{$keyword}} => $c;
                push @{$itemcomment{$line}} => $c;
            }
            ## Empty out our user comment queue
            undef @comment;
        }

        ## What file(s) are we checking on?
        if (/^FILE(\d*):\s*(.+?)\s*$/) {

            my $suffix = $1 || 0;
            my $filename = $2;

            ## Basic sanity check
            if ($filename !~ /\w/) {
                die "No valid FILE found in the config file! (tried: $filename)\n";
            }

            ## If files were specified on the command line, use those instead
            if ($arg{file}[0]) {

                ## Have we been here already? Only need to override once
                if (! exists  $localopt{filename}) {

                    for my $argfile (@{ $arg{file} }) {

                        ## If it contains a path, use it directly
                        if ($argfile =~ m{/}) {
                            $filename = $argfile;
                        }
                        ## Otherwise, replace the current file name but keep the directory
                        else {
                            my $dir = dirname($filename);
                            $filename = "$dir/$argfile";
                        }

                        ## Add it to our local list both as final and original name
                        push @{ $localopt{file} } => {
                            name => $filename,
                            original => $filename,
                            commandline => 1,
                            lastfile => '',
                            offset => 0,
                        };
                    }

                    next;
                }
            }

            ## If the file contains % escapes, replace with the actual time
            my $newfilename = transform_filename($filename);

            ## Save to the local list, storing the original filename for config rewriting
            push @{ $localopt{file} } =>
                {
                 name => $newfilename,
                 original => $filename,
                 suffix => $suffix,
                 };
        } ## end of FILE:

        ## The last filename we used
        elsif (/^LASTFILE(\d*):\s*(.+?)\s*$/) {
            my $suffix = $1 || 1;
            $localopt{lastfile}{$suffix} = $2;
        }
        ## Who to send emails to for this file
        elsif (/^EMAIL:\s*(.+?)\s*$/) {
            push @{$localopt{email}}, $1;
        }
        ## Who to send emails from
        elsif (/^FROM:\s*(.+?)\s*$/) {
            $localopt{from} = $1;
        }
        ## What type of report this is
        elsif (/^TYPE:\s*(.+?)\s*$/) {
            $arg{type} = $1;
        }
        ## Exclude durations below this number
        elsif (/^DURATION:\s*(\d+)/) {
            ## Command line still wins
            if ($arg{duration} < 0) {
                $arg{duration} = $localopt{duration} = $1;
            }
        }
        ## Limit how many duration matches we show
        elsif (/^DURATION_LIMIT:\s*(\d+)/) {
            ## Command line still wins
            if (!$arg{duration_limit}) {
                $arg{duration_limit} = $localopt{duration_limit} = $1;
            }
        }
        ## Exclude tempfiles below this number
        elsif (/^TEMPFILE:\s*(\d+)/) {
            ## Command line still wins
            if ($arg{tempfile} < 0) {
                $arg{tempfile} = $localopt{tempfile} = $1;
            }
        }
        ## Limit how many tempfile matches we show
        elsif (/^TEMPFILE_LIMIT:\s*(\d+)/) {
            ## Command line still wins
            if (!$arg{tempfile_limit}) {
                $arg{tempfile_limit} = $localopt{tempfile_limit} = $1;
            }
        }
        ## Allow a very local log_line_prefix
        elsif (/^LOG_LINE_PREFIX:\s*(.+)/) {
            $arg{log_line_prefix} = $localopt{log_line_prefix} = $1;
        }
        ## How to sort the output
        elsif (/^SORTBY:\s*(\w+)/) {
            $localopt{sortby} = $1;
        }
        ## Force line number lookup on or off
        elsif (/^FIND_LINE_NUMBER:\s*(\d+)/) {
            $arg{find_line_number} = $localopt{find_line_number} = $1;
        }
        ## Any inheritance files to look at
        elsif (/^INHERIT:\s*(.+)/) {
            push @{$localopt{inherit}}, $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE:\s*(.+?)\s*$/) {
            push @{$localopt{exclude}}, $1;
        }
        ## Which prefix lines to exclude from the report
        elsif (/^EXCLUDE_PREFIX:\s*(.+?)\s*$/) {
            push @{$localopt{exclude_prefix}}, $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE_NON_PARSED:\s*(.+?)\s*$/) {
            push @{$localopt{exclude_non_parsed}}, $1;
        }
        ## Which lines to include in the report
        elsif (/^INCLUDE:\s*(.+)/) {
            push @{$localopt{include}}, $1;
        }
        ## The current offset into a file
        elsif (/^OFFSET(\d*):\s*(\d+)/) {
            my $suffix = $1 || 1;
            $localopt{offset}{$suffix} = $2;
        }
        ## The custom maxsize for all files
        elsif (/^MAXSIZE:\s*(\d+)/) {
            $localopt{maxsize} = $1;
        }
        ## The subject line
        elsif (/^MAILSUBJECT:\s*(.+)/) { ## Trailing whitespace is significant here
            $localopt{mailsubject} = $1;
            $localopt{customsubject} = 1;
        }
        ## Force mail to be sent - overrides any other setting
        elsif (/^MAILZERO:\s*(.+)/) {
            $localopt{mailzero} = $1;
        }
        ## Allow (possibly multiple) mail signatures
        elsif (/^MAILSIG:\s*(.+)/) {
            push @{$localopt{mailsig}}, $1;
            push @{$arg{mailsig}}, $1;
        }
        ## Size at which we cutoff long statements
        elsif (/^STATEMENT_SIZE:\s*(.+)/) {
            $localopt{statement_size} = $1;
        }
    }
    close $c or die qq{Could not close "$configfile": $!\n};

    ## Adjust the file suffixes as needed
    ## This allows us to simply add multiple bare 'FILE:' entries before the first rewrite
    ## We also plug in the LASTFILE AND OFFSET values now
    my %numused;
    for my $file (@{ $localopt{file} }) {
        $file->{suffix} ||= 0;
        next if ! $file->{suffix};
        if ($numused{$file->{suffix}}++) {
            die "The same FILE suffix ($file->{suffix}) was used more than once!\n";
        }
    }
    for my $file (@{ $localopt{file} }) {

        ## No need to change anything if we forced via the command line
        next if $file->{commandline};

        ## Only need to adjust 0s
        if (! $file->{suffix}) {

            ## Replace with the first free number
            my $x = 1;
            {
                if (! $numused{$x}++) {
                    $file->{suffix} = $x;
                    last;
                }
                if ($x++ > 999) {
                    die "Something went wrong: 999 iterations to find a FILE suffix!\n";
                }
                redo;
            }
        }

        ## Put the lastfile into place if it exists
        $file->{lastfile} = $localopt{lastfile}{$file->{suffix}} || '';

        ## Put the offset into place if it exists
        $file->{offset} = $localopt{offset}{$file->{suffix}} || 0;

    }

    ## Move the local vars into place, also record that we found them here
    for my $k (keys %localopt) {
        ## Note it came from the config file so we rewrite it there
        $opt{configfile}{$k} = 1;
        ## If an array, we also want to mark individual items
        if (ref $localopt{$k} eq 'ARRAY') {
            for my $ik (@{$localopt{$k}}) {
                $opt{configfile}{"$k.$ik"} = 1;
            }
        }
        $opt{$k} = $localopt{$k};
    }

    if ($arg{debug}) {
        local $Data::Dumper::Varname = 'opt';
        warn Dumper \%opt;
        local $Data::Dumper::Varname = 'arg';
        warn Dumper \%arg;
    }

    return;

} ## end of parse_config_file


sub parse_inherited_files {

    ## Call parse_inherit_file on each item in $opt{inherit}

    for my $file (@{$opt{inherit}}) {
        parse_inherit_file($file);
    }

    return;

} ## end of parse_inherited_files


sub parse_inherit_file {

    ## Similar to parse_config_file, but much simpler
    ## Because we only allow a few items
    ## This is most useful for sharing INCLUDE and EXCLUDE across many config files

    my $file = shift;

    ## Only allow certain characters.
    if ($file !~ s{^\s*([a-zA-Z0-9_\.\/\-\=]+)\s*$}{$1}) {
        die "Invalid inherit file ($file)\n";
    }

    ## If not an absolute path, we'll check current directory and "tnm/"
    my $filename = $file;
    my $filefound = 0;
    if (-e $file) {
        $filefound = 1;
    }
    elsif ($file =~ /^\w/) {
        $filename = "tnm/$file";
        if (-e $filename) {
            $filefound = 1;
        }
        else {
            my $basedir = dirname($0);
            $filename = "$basedir/$file";
            if (-e $filename) {
                $filefound = 1;
            }
            else {
                $filename = "$basedir/tnm/$file";
                if (-e $filename) {
                    $filefound = 1;
                }
                else {
                    ## Use the config file's directory
                    my $basedir2 = dirname($configfile);
                    $filename = "$basedir2/$file";
                    if (-e $filename) {
                        $filefound = 1;
                    }
                    else {
                        $filename = "basedir2/tnm/$file";
                        if (-e $filename) {
                            $filefound = 1;
                        }
                        else {
                            ## Try the home directory/tnm
                            $filename = "$ENV{HOME}/tnm/$file";
                            -e $filename and $filefound = 1;
                        }
                    }
                }
            }
        }
    }
    if (!$filefound) {
        die "Unable to open inherit file ($file)\n";
    }

    open my $fh, '<', $filename or die qq{Could not open file "$file": $!\n};
    while (<$fh>) {
        chomp;
        next if /^#/ or ! /\w/;
        ## Only a few things are allowed in here
        if (/^FIND_LINE_NUMBER:\s*(\d+)/) {
            ## We adjust the global here and now
            $arg{find_line_number} = $1;
        }
        ## How to sort the output
        elsif (/^SORTBY:\s*(\w+)/) {
            $opt{sortby} = $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE:\s*(.+?)\s*$/) {
            push @{$opt{exclude}}, $1;
        }
        ## Which prefix lines to exclude from the report
        elsif (/^EXCLUDE_PREFIX:\s*(.+?)\s*$/) {
            push @{$opt{exclude_prefix}}, $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE_NON_PARSED:\s*(.+?)\s*$/) {
            push @{$opt{exclude_non_parsed}}, $1;
        }
        ## Which lines to include in the report
        elsif (/^INCLUDE:\s*(.+)/) {
            push @{$opt{include}}, $1;
        }
        ## Maximum file size
        elsif (/^MAXSIZE:\s*(\d+)/) {
            $opt{maxsize} = $1;
        }
        ## Exclude durations below this number
        elsif (/^DURATION:\s*(\d+)/) {
            ## Command line still wins
            if ($arg{duration} < 0) {
                $arg{duration} = $1;
            }
        }
        ## Duration limit
        elsif (/^DURATION_LIMIT:\s*(\d+)/) {
            ## Command line still wins
            $arg{duration_limit} ||= $1;
        }
        ## Exclude tempfiles below this number
        elsif (/^TEMPFILE:\s*(\d+)/) {
            ## Command line still wins
            if ($arg{tempfile} < 0) {
                $arg{tempfile} = $1;
            }
        }
        ## Tempfile limit
        elsif (/^TEMPFILE_LIMIT:\s*(\d+)/) {
            ## Command line still wins
            $arg{tempfile_limit} ||= $1;
        }
        ## Who to send emails from
        elsif (/^FROM:\s*(.+?)\s*$/) {
            $opt{from} = $1;
        }
        ## Who to send emails to for this file
        elsif (/^EMAIL:\s*(.+?)\s*$/) {
            push @{$opt{email}}, $1;
        }
        ## Force mail to be sent - overrides any other setting
        elsif (/^MAILZERO:\s*(.+)/) {
            $opt{mailzero} = $1;
        }
        ## The file to use
        elsif (/^FILE(\d*):\s*(.+)/) {

            my $suffix = $1 || 0;
            my $filename = $2;

            ## Skip entirely if we have a command-line file request
            ## This is handled in the main config parsing
            next if $arg{file}[0];

            ## As with the normal config file, store a temp version
            ## Save to the local list, storing the original filename for config rewriting
            push @{ $opt{tempifile} } =>
                {
                 original => $filename,
                 suffix => $suffix,
                 };
        }
        ## The mail subject
        elsif (/^MAILSUBJECT:\s*(.+)/) {
            $opt{mailsubject} = $1;
            $opt{customsubject} = 1;
        }
        ## The mail signature
        elsif (/^MAILSIG:\s*(.+)/) {
            push @{$opt{mailsig}}, $1;
        }
        ## The log line prefix
        elsif (/^LOG.LINE.PREFIX:\s*(.+)/o) {
            $opt{log_line_prefix} = $1;
        }
        ## Size at which we cutoff long statements
        elsif (/^STATEMENT_SIZE:\s*(.+)/) {
            $opt{statement_size} = $1;
        }
        else {
            warn qq{Unknown item in include file "$file": $_\n};
        }

    }
    close $fh or warn qq{Could not close file "$file": $!\n};

    ## Merge all the "FILE" entries and adjust suffixes
    ## We allow overlap between the normal and inherited lists

    if (exists $opt{tempifile}) {

        my %numused;
        for my $file (@{ $opt{tempifile} }) {
            $file->{suffix} ||= 0;
            next if ! $file->{suffix};
            if ($numused{$file->{suffix}}++) {
                die "The same FILE suffix ($file->{suffix}) was used more than once inside $filename!\n";
            }
        }

        for my $file (@{ $opt{tempifile} }) {

            ## Change zero to the first free number
            if (! $file->{suffix}) {
                my $x = 1;
                {
                    if (! $numused{$x}++) {
                        $file->{suffix} = $x;
                        last;
                    }
                    if ($x++ > 999) {
                        die "Something went wrong: 999 iterations to find a FILE suffix inside $filename!\n";
                    }
                    redo;
                }
            }

            ## Create our real entry
            push @{ $opt{file} } =>
                {
                 name      => transform_filename($file->{original}),
                 original  => $file->{original},
                 suffix    => $file->{suffix},
                 inherited => 1,
                 };
        }

        ## Remove our temporary list
        delete $opt{tempifile};
    }

    return;

} ## end of parse_inherited_file


sub parse_file {

    ## Parse a file - this is the workhorse
    ## Arguments: two
    ## 1. Exact filename we are parsing
    ## 2. Hashref of file information:
    ##   name: logfile to open
    ##   original: original name
    ##   lastfile: we scanned last time this ran. May be an empty string or not exist
    ##   offset: where in the file we stopped at last time
    ## Returns the number of matches

    my $filename = shift;
    my $fileinfo = shift;

    ## The file we scanned last time we ran
    my $lastfile = $fileinfo->{lastfile} || '';
    
    ## Set this as the latest (but not the lastfile)
    $fileinfo->{latest} = $filename;

    ## Touch the hash so we know we've been here
    $find{$filename} = {};

    ## Make sure the file exists and is readable
    if (! -e $filename) {
        $arg{quiet} or warn qq{WARNING! Skipping non-existent file "$filename"\n};
        return -1;
    }
    if (! -f $filename) {
        $arg{quiet} or warn qq{WARNING! Skipping non-file "$filename"\n};
        return -1;
    }

    ## Figure out where in the file we want to start scanning from
    my $size = -s $filename;
    my $offset = 0;
    my $maxsize = $opt{maxsize} ? $opt{maxsize} : $arg{maxsize};

    ## Is the offset significant?
    if (!$arg{file}[0]               ## ...not if we passed in filenames manually
        and $lastfile eq $filename   ## ...not if this is not the same file we got the offset for last time
        ) {
        ## Allow the offset to equal the size via --reset
        if ($arg{reset}) {
            $offset = $size;
            $arg{verbose} and warn "  Resetting offset to $offset\n";
        }
        ## Allow the offset to be changed on the command line
        elsif ($arg{offset} != -1) {
            if ($arg{offset} >= 0) {
                $offset = $arg{offset};
            }
            elsif ($arg{offset} < -1) {
                $offset = $size + $arg{offset};
                $offset = 0 if $offset < 0;
            }
        }
        else{
            $offset = $fileinfo->{offset} || 0;
        }
    }

    my $psize = pretty_number($size);
    my $pmaxs = pretty_number($maxsize);
    my $poffset = pretty_number($offset);
    $arg{verbose} and warn "  File: $filename Offset: $poffset Size: $psize Maxsize: $pmaxs\n";

    ## The file may have shrunk due to a logrotate
    if ($offset > $size) {
        $arg{verbose} and warn "  File has shrunk - resetting offset to 0\n";
        $offset = 0;
    }

    ## If the offset is equal to the size, we're done!
    ## Store the offset if it is truly new and significant
    if ($offset >= $size) {
        $offset = $size;
        if ($offset and $fileinfo->{offset} != $offset) {
            $opt{newoffset}{$filename} = $offset;
        }
        return 0;
    }

    ## Store the original offset
    my $original_offset = $offset;

    ## This can happen quite a bit on busy files!
    if ($maxsize and ($size - $offset > $maxsize) and $arg{offset} < 0) {
        $arg{quiet} or warn "  SIZE TOO BIG (size=$size, offset=$offset): resetting to last $maxsize bytes\n";
        $toolarge{$filename} = qq{File "$filename" too large:\n  only read last $maxsize bytes (size=$size, offset=$offset)};
        $offset = $size - $maxsize;
    }

    open my $fh, '<', $filename or die qq{Could not open "$filename": $!\n};

    ## Seek the right spot as needed
    if ($offset and $offset < $size) {

        ## Because we go back by 10 characters below, always offset at least 10
        $offset = 10 if $offset < 10;

        ## We go back 10 characters to get us before the newlines we (probably) ended with
        seek $fh, $offset-10, 0;

        ## If a manual rewind request has been given, process it (inverse)
        if ($arg{rewind}) {
            seek $fh, -$arg{rewind}, 1;
        }
    }

    ## Optionally figure out what approximate line we are on
    my $newlines = 0;
    if ($arg{find_line_number}) {
        my $pos = tell $fh;

        ## No sense in counting if we're at the start of the file!
        if ($pos > 1) {

            seek $fh, 0, 0;
            ## Need to sysread up to $pos
            my $blocksize = 100_000;
            my $current = 0;
            {
                my $chunksize = $blocksize;
                if ($current + $chunksize > $pos) {
                    $chunksize = $pos - $current;
                }
                my $foobar;
                my $res = read $fh, $foobar, $chunksize;
                ## How many newlines in there?
                $newlines += $foobar =~ y/\n/\n/;
                $current += $chunksize;
                redo if $current < $pos;
            }

            ## Return to the original position
            seek $fh, 0, $pos;

        } ## end pos > 1

    } ## end find_line_number

    ## Get exclusion and inclusion regexes for this file
    ($exclude,$include,$exclude_prefix,$exclude_non_parsed) = generate_regexes($filename);
    
    ## Discard the previous line if needed (we rewound by 10 characters above)
    $original_offset and <$fh>;

    ## Keep track of matches for this file
    my $count = 0;

    ## Needed to track postgres PIDs
    my %pidline;

    ## Switch to CSV mode if required of if the file ends in '.csv'
    if (lc $arg{pglog} eq 'csv' or $filename =~ /\.csv$/) {
        if (! defined $csv) {
            eval {
                require Text::CSV;
            };
            if (!$@) {
                $csv = Text::CSV->new({ binary => 1, eol => $/ });
            }
            else {
                ## Assume it failed because it doesn't exist, so try another version
                eval {
                    require Text::CSV_XS;
                };
                if ($@) {
                    die qq{Cannot parse CSV logs unless Text::CSV or Text::CSV_XS is available\n};
                }
                $csv = Text::CSV_XS->new({ binary => 1, eol => $/ });
            }
        }
        while (my $line = $csv->getline($fh)) {
            my @cols = @$line;
            my $prefix = "$line->[0] \[$line->[3]\]";
            my $context = length $line->[18] ? "CONTEXT: $line->[18] " : '';
            my $raw = "$line->[11]:  $line->[13] ${context}STATEMENT:  $line->[19]";
            $count += process_line({pgprefix => $prefix, rawstring => $raw, line => $.}, $., $filename);
        }

    } ## end of PG CSV mode
    else {
        ## Postgres-specific multi-line grabbing stuff:
        my ($pgts, $pgpid, %current_pid_num, $lastpid, $pgprefix);
        my $pgnum = 1;
        my $lastline = '';
        my $syslognum = 0; ## used by syslog only
        my $bailout = 0; ## emergency bail out in case we end up sleep seeking
# DEBUG!
	  	my $processed = 1;
		my $prev_line = '';
		
      LOGLINE: while (<$fh>) {
# DEBUG!
			if(! $processed ) {
				$count += process_line($prev_line, $. + $newlines, $filename);
			}
			$processed = 0;			
			$prev_line = $_;

            ## We ran into a truncated line last time, so we are most likely done
            last if $bailout;

            ## Easiest to just remove the newline here and now
            if (! chomp) {
                ## There was no newline, so it's possible some other process is in
                ## the middle of writing this line. Just in case this is so, sleep and
                ## let it finish, then try again. Because we don't want to turn this
                ## into a tail -f situation, bail out of the loop once done
                sleep 1;
                ## Rewind just far enough to try this line again
                seek $fh, - (length $_), 1;
                $_ = <$fh>;
                if (! chomp) {
                    ## Still no go! Let's just leave and abandon this line
                    last LOGLINE;
                }
                ## Success! Finish up this line, but then abandon any further slurping
                $bailout = 1;
            }
            if ($arg{pgmode}) {
                ## 1=prefix 2=timestamp 3=PID 4=rest
                if ($_ =~ s/$pgpidre/$4/) {

                    ## We want the timestamp and the pid, even if we have to fake it
                    ($pgprefix,$pgts,$pgpid,$pgnum) = ($1, $2||'', $3||1, 1);

                    $pgprefix =~ s/\s+$//o;
                    if ($arg{pglog} eq 'syslog') {
                        if ($pgprefix =~ /\[(\d+)\-\d+/) {
                            $pgnum = $1;
                        }
                    }

                    $lastpid = $pgpid;

                    ## Have we seen this PID before?
                    if (exists $pidline{$pgpid}) {
                        if ($arg{pglog} eq 'syslog') {
                            if ($syslognum and $syslognum != $pgnum) {
                                ## Got a new statement, so process the old
# DEBUG!
                                $count += process_line(delete $pidline{$pgpid}, 0, $filename);
								$processed++;
                            }
                        }
                        else {
                            ## Append to the string for this PID
                            if (/\b(?:STATEMENT|DETAIL|HINT|CONTEXT|QUERY):  /o) {
                                ## Increment the pgnum by one
                                $pgnum = $current_pid_num{$pgpid} + 1;
                            }
                            else {
                                ## Process the old one
                                ## Delete it so it gets recreated afresh below
# DEBUG!
                                $count += process_line(delete $pidline{$pgpid}, 0, $filename);
								$processed++;
                            }
                        }
                    }

                    if ($arg{pglog} eq 'syslog') {
                        $syslognum = $pgnum;
                        ## Increment our arbitrary internal number
                        $current_pid_num{$pgpid} ||= 0;
                        $pgnum = $current_pid_num{$pgpid} + 1;
                    }

                    ## Optionally strip out SQLSTATE codes
                    if ($arg{sqlstate}) {
                        $_ =~ s/^(?:FATAL|ERROR):  ([0-9A-Z]{5}): /ERROR:  /o;
                    }

                    ## Assign this string to the current pgnum slot
                    $pidline{$pgpid}{string}{$pgnum} = $_;
                    $current_pid_num{$pgpid} = $pgnum;

                    ## If we don't yet have a line, store it, plus the prefix and timestamp
                    if (! $pidline{$pgpid}{line}) {
                        $pidline{$pgpid}{line} = ($. + $newlines);
                        $pidline{$pgpid}{pgprefix} = $pgprefix;
                        $pidline{$pgpid}{pgtime} = $pgts;
                    }

                    ## Remember this line
                    $lastline = $_;

                    ## We are done: go the next line
                    next LOGLINE;
                }

                ## We did not match the log_line_prefix

                ## May be a continuation or a special LOG line (e.g. autovacuum)
                ## If it is, we'll simply ignore it
                if ($_ =~ m{$pgpidre2}) {
                    if ($arg{debug}) {
                        warn "Skipping line $_\n";
                    }
                    next LOGLINE;
                }

                ## If we do not have a PID yet, skip this line
                next LOGLINE if ! $lastpid;

                ## If there is a leading tab, remove it and treat as a continuation
                if (s{^\t}{ }) {
                    ## Increment the pgnum
                    $pgnum = $current_pid_num{$lastpid} + 1;
                    $current_pid_num{$lastpid} = $pgnum;

                    ## Store this string
                    $pidline{$lastpid}{string}{$pgnum} = $_;
                }
                ## May be a special LOG entry with no %u@%d etc.
                ## We simply skip these ones if they go into a LOG:
                elsif ($_ =~ m{$pgpidre3\s+LOG:}) {
                    next LOGLINE;
                }
                else {
                    ## Not a continuation, so probably an error from the OS
                    ## Simply parse it right away, force it to match
                    if (! $arg{skip_non_parsed}) {
# DEBUG!
                        $count += process_line($_, $. + $newlines, $filename, 1);
						$processed--;
                    }
                }

                ## No need to do anything more right now if in pgmode
                next LOGLINE;

            } ## end of normal pgmode

            ## Just a bare entry, so process it right away
# DEBUG!
            $count += process_line($_, $. + $newlines, $filename);
			$processed++;

        } ## end of each line in the file

    } ## end of non-CSV mode
    
    ## Get the new offset and store it
    seek $fh, 0, 1;
    $offset = tell $fh;
    if ($fileinfo->{offset} != $offset and $offset) {
        $opt{newoffset}{$filename} = $offset;
    }

    close $fh or die qq{Could not close "$filename": $!\n};

    ## Now add in any pids that have not been processed yet
    for my $pid (sort { $pidline{$a}{line} <=> $pidline{$b}{line} } keys %pidline) {
        $count += process_line($pidline{$pid}, 0, $filename);
    }

    if (!$count) {
        $arg{verbose} and warn "  No new lines found in file $filename\n";
    }
    else {
        $arg{verbose} and warn "  Lines found in $filename: $count\n";
    }

    $opt{grand_total} += $count;

    return $count;

} ## end of parse_file


sub transform_filename {

    my $name = shift or die;

    ## Transform the file name if it contains escapes
    if ($name =~ /%/) {
        ## Allow moving back in time with the timewarp argument (defaults to 0)
        my @ltime = localtime(time + $arg{timewarp});
        $name = strftime($name, @ltime);
    }

    return $name;

} ## end of transform_filename


sub generate_regexes {

    ## Given a filename, generate exclusion and inclusion regexes for it

    ## Currently, all files get the same regex, so we cache it
    if (exists $opt{globalexcluderegex}) {
        return $opt{globalexcluderegex}, $opt{globalincluderegex}, $opt{globalexcludeprefixregex}, $opt{globalexcludenonparsedregex};

    }

    ## Build an exclusion regex
    my $lexclude = '';
    for my $ex (@{$opt{exclude}}) {
        $arg{debug} and warn "  Adding exclusion: $ex\n";
        my $regex = qr{$ex};
        $lexclude .= "$regex|";
    }
    $lexclude =~ s/\|$//;
    $arg{verbose} and $lexclude and warn "  Exclusion: $lexclude\n";

    ## Build an exclusion non-parsed regex
    my $lexclude_non_parsed = '';
    for my $ex (@{$opt{exclude_non_parsed}}) {
        $arg{debug} and warn "  Adding exclusion_non_parsed: $ex\n";
        my $regex = qr{$ex};
        $lexclude_non_parsed .= "$regex|";
    }
    $lexclude_non_parsed =~ s/\|$//;
    $arg{verbose} and $lexclude_non_parsed and warn "  Exclusion_non_parsed: $lexclude_non_parsed\n";

    ## Build a prefix exclusion regex
    my $lexclude_prefix = '';
    for my $ex (@{$opt{exclude_prefix}}) {
        $arg{debug} and warn "  Adding exclusion_prefix: $ex\n";
        my $regex = qr{$ex};
        $lexclude_prefix .= "$regex|";
    }
    $lexclude_prefix =~ s/\|$//;
    $arg{verbose} and $lexclude_prefix and warn "  Exclusion_prefix: $lexclude_prefix\n";

    ## Build an inclusion regex
    my $linclude = '';
    for my $in (@{$opt{include}}) {
        $arg{debug} and warn "  Adding inclusion: $in\n";
        my $regex = qr{$in};
        $linclude .= "$regex|";
    }
    $linclude =~ s/\|$//;
    $arg{verbose} and $linclude and warn "  Inclusion: $linclude\n";

    $opt{globalexcluderegex} = $lexclude;
    $opt{globalexcludeprefixregex} = $lexclude_prefix;
    $opt{globalexcludenonparsedregex} = $lexclude_non_parsed;
    $opt{globalincluderegex} = $linclude;

    return $lexclude, $linclude, $lexclude_prefix, $lexclude_non_parsed;

} ## end of generate_regexes


sub process_line {
    ## We've got a complete statement, so do something with it!
    ## If it matches, we'll either put into %find directly, or store in %similar

    my ($info,$line,$filename,$forcematch) = @_;

    ## The final string
    $string = '';
    ## The prefix
    my $pgprefix = '';
    ## The timestamp
    $time = '';

    if (ref $info eq 'HASH') {
        $pgprefix = $info->{pgprefix} if exists $info->{pgprefix};
        $time = $info->{pgtime} if exists $info->{pgtime};
        if (exists $info->{rawstring}) {
            $string = $info->{rawstring};
        }
        else {
            for my $l (sort {$a<=>$b} keys %{$info->{string}}) {
                ## Some Postgres/syslog combos produce ugly output
                $info->{string}{$l} =~ s/^(?:\s*#011\s*)+//o;
                $string .= ' '.$info->{string}{$l};
            }
        }
        $line = $info->{line};
    }
    else {
        $string = $info;
    }

    ## Strip out leading whitespace
    $string =~ s/^\s+//o;

    ## Save the raw version
    my $rawstring = $string;

    ## Special handling for forced checks, e.g. OS errors
    if (defined $forcematch) {
        $pgprefix = '?';

        ## Bail if it matches the exclusion non-parsed regex
        return 0 if $exclude_non_parsed and $string =~ $exclude_non_parsed;

        goto PGPREFIX;
    }
    ## A forced match skips both checks below
    else {

        ## Bail if it does not match the inclusion regex
        return 0 if $include and $string !~ $include;

        ## Bail if it matches the exclusion regex
        return 0 if $exclude and $string =~ $exclude;

        ## Bail if it matches the prefix exclusion regex
        return 0 if $exclude_prefix and $pgprefix =~ $exclude_prefix;
    }

    ## If in duration mode, and we have a minimum cutoff, discard faster ones
    if ($arg{type} eq 'duration' and $arg{duration} >= 0) {
        return 0 if ($string =~ / duration: (\d+)/o and $1 < $arg{duration});
    }

    $arg{debug} and warn "MATCH at line $line of $filename\n";

    ## Force newlines to a single line
    $string =~ s/\n/\\n/go;

    ## Compress all whitespace
    $string =~ s/\s+/ /go;

    ## Strip leading whitespace
    $string =~ s/^\s+//o;

    ## If not in Postgres mode, we avoid all the mangling below
    if (! $arg{pgmode}) {
        $find{$filename}{$line} =
                {
                 string   => $string,
                 line     => $line,
                 filename => $filename,
                 count    => 1,
                 };

        return 1;
    }

    ## For tempfiles, strip out the size information and store it
    my $tempfilesize = 0;
    if ($arg{type} eq 'tempfile') {
        if ($string =~ s/LOG: temporary file:.+?size (\d+)\s*//o) {
            $tempfilesize = $1;
        }
        else {
            ## If we cannot figure out a size, skip this line
            return 1;
        }
        $string =~ s/^\s*STATEMENT:\s*//o;
    }

    ## Reassign rawstring
    $rawstring = $string;

    ## Make some adjustments to attempt to compress similar entries
    if ($arg{flatten} and $arg{type} ne 'duration') {

        ## Simplistic SELECT func(arg1,arg2,...) replacement
        $string =~ s{(SELECT\s*\w+\s*\()([^*].*?)\)}{
            my ($select,$args) = ($1,$2);
            my @arg;
            for my $arg (split /,/ => $args) {
                $arg =~ s/^\s*(.+?)\s*$/$1/;
                $arg = '?' if $arg !~ /^\$\d/;
                push @arg => $arg;
            }
            "$select" . (join ',' => @arg) . ')';
        }geix;

        my $thisletter = '';

        $string =~ s{(VALUES|REPLACE)\s*\((.+)\)}{ ## For emacs: ()()()
            my ($sword,$list) = ($1,$2);
            my @word = split(//, $list);
            my $numitems = 0;
            my $status = 'start';
            my @dollar;

          F: for (my $x = 0; $x <= $#word; $x++) {

                $thisletter = $word[$x];
                if ($status eq 'start') {

                    ## Ignore white space and commas
                    if ($thisletter eq ' ' or $thisletter eq '    ' or $thisletter eq ',') {
                        next F;
                    }

                    $numitems++;
                    ## Is this a normal quoted string?
                    if ($thisletter eq q{'}) {
                        $status = 'inquote';
                        next F;
                    }
                    ## Perhaps E'' quoting?
                    if ($thisletter eq 'E') {
                        if (defined $word[$x+1] and $word[$x+1] ne q{'}) {
                            ## So weird we'll just pass it through
                            $status = 'fail';
                            last F;
                        }
                        $x++;
                        $status = 'inquote';
                        next F;
                    }
                    ## Dollar quoting
                    if ($thisletter eq '$') {
                        undef @dollar;
                        {
                            push @dollar => $word[$x++];
                            ## Give up if we don't find a matching dollar
                            if ($x > $#word) {
                                $status = 'fail';
                                last F;
                            }
                            if ($thisletter eq '$') {
                                $status = 'dollar';
                                next F;
                            }
                            redo;
                        }
                    }
                    ## Must be a literal
                    $status = 'literal';
                    next F;
                } ## end status 'start'

                if ($status eq 'literal') {

                    ## May be the end of the whole section
                    if ($thisletter eq ';') {
                        $sword .= "(?);";
                        $numitems = 0;

                        ## Grab everything forward from this point
                        my $newlist = substr($list,$x+1);

                        if ($newlist =~ m{(.+?(?:VALUES|REPLACE))\s*\(}io) {
                            $sword .= $1;
                            $x += length $1;
                        }

                        $status = 'start';
                        next F;
                    }

                    ## Almost always numbers. Just go until a comma
                    if ($thisletter eq ',') {
                        $status = 'start';
                    }
                    next F;
                }

                if ($status eq 'inquote') {
                    ## The only way out is an unescaped single quote
                    if ($thisletter eq q{'}) {
                        next F if $word[$x-1] eq '\\';
                        if (defined $word[$x+1] and $word[$x+1] eq q{'}) {
                            $x++;
                            next F;
                        }
                        $status = 'start';
                    }
                    next F;
                }

                if ($status eq 'dollar') {
                    ## Only way out is a matching dollar escape
                    if ($thisletter eq '$') {
                        ## Possibility
                        my $oldpos = $x++;
                        for (my $y=0; $y <= $#dollar; $y++, $x++) {
                            if ($dollar[$y] ne $thisletter) {
                                ## Tricked us - reset to next position
                                $x = $oldpos;
                                next F;
                            }
                        }
                        ## Got a match!
                        $x++;
                        $status = 'start';
                        next F;
                    }
                }

            } ## end each letter (F)

            if ($status eq 'fail') {
                "$sword ($list)";
            }
            else {
                "$sword (?)";
            }
        }geix;
        $string =~ s{(\bWHERE\s+\w+\s*=\s*)\d+}{$1?}gio;
        $string =~ s{(\bWHERE\s+\w+\s+IN\s*\((?!\s*SELECT))[^)]+\)}{$1?)}gio;
        $string =~ s{(\bWHERE\s+\w+[\.\w]*\s*=\s*)'.+?'}{$1'?')}gio;
        $string =~ s{(\bWHERE\s+\w+[\.\w]*\s*=\s*)\d+}{$1'?')}gio;
        $string =~ s{(,\s*)'.+?'(\s*AS\s*\w+\b)}{$1'?'$2)}gio;
        $string =~ s{(UPDATE\s+\w+\s+SET\s+\w+\s*=\s*)'[^']*'}{$1'?'}go;
        $string =~ s/(invalid byte sequence for encoding "UTF8": 0x)[a-f0-9]+/$1????/o;
        $string =~ s{(\(simple_geom,)'.+?'}{$1'???'}gio;
        $string =~ s{(DETAIL: Key \([\w, ]+\))=\(.+?\)}{$1=(?)}go;
        $string =~ s{Failed on request of size \d+}{Failed on request of size ?}go;
        $string =~ s{ARRAY\[.+?\]}{ARRAY[?]}go;
        $string =~ s{(invalid input syntax for integer:) ".+?"}{$1: "?"}o;
        $string =~ s{value ".+?" (is out of range for type)}{value "?" $1}o;
        $string =~ s{(Failing row contains) \(.+?\)\.}{$1 \(?\)\.}go;

        ## Syntax error at a specific character
        $string =~ s{(syntax error at or near) "\w+" at character \d+}{$1 "?" at character ?}o;

        ## Ambiguity at a specific character
        $string =~ s{(" is ambiguous at character )\d+}{$1 ?}o;

        ## Case of hard-coded numbers at the start of an inner SELECT
        $string =~ s{(\bSELECT\s*)\d+,\s*\d+,}{$1 ?,?,}gio;

        ## Some PostGIS functions
        $string =~ s{(\bST_GeomFromText\(').*?',\d+\)}{$1(?,?)}gio;

        ## Declaring a named cursor
        $string =~ s{\b(DECLARE\s*(\S+)\s*CURSOR\b)}{DECLARE ? CURSOR}gio;

        ## Simple numbers after an AND
        $string =~ s{(\s+AND\s+\w+)\s*=\d+(\b)}{$1=?$2}gio;

        ## Simple numbers after a SELECT
        $string =~ s{(\bSELECT\s+)\d+(\b)}{$1?$2}gio;

        ## Raw number surrounded by commas
        $string =~ s{(,\s*)\d+(\s*,)}{$1?$2}go;

        ## Timestamps as values
        $string =~ s{\s*=\s*'\d\d\d\d\-\d\d\-\d\d \d\d:\d\d:\d\d\.\d\d\d\d\d\d'}{=?}go;

    } ## end of flatten

    ## Format the final string (and rawstring) a little bit
    if ($arg{pretty_query}) {
        for my $word (qw/DETAIL HINT QUERY CONTEXT STATEMENT/) {
            $string =~ s/ *$word: /\n$word: /;
            $rawstring =~ s/ *$word: /\n$word: /;
        }
        if ($arg{type} eq 'duration') {
            $string =~ s/LOG: duration: (\d+\.\d+ ms) LOG: statement: /DURATION: $1\nSTATEMENT: /o;
            $rawstring =~ s/LOG: duration: (\d+\.\d+ ms) LOG: statement: /DURATION: $1\nSTATEMENT: /o;
        }
        $rawstring =~ s/^([A-Z]+: ) +/$1/gmo;
    }

    ## Special handling for tempfile mode
    if ($arg{type} eq 'tempfile') {
        ## We should know the temp file size by now
        ## We want to store up to four possible versions of a statment:
        ## Earliest, latest, smallest, largest

        ## The record we are going to store
        my $thisrecord = {
            filename => $filename,
            line     => $line,
            pgprefix => $pgprefix,
            time     => $time,
            filesize => $tempfilesize,
        };


        ## If we've not seen this before, simply create the structure and go
        if (! exists $similar{$string}) {

            ## Store all four versions as the same structure
            $similar{$string}{earliest} =
            $similar{$string}{latest} =
            $similar{$string}{smallest} =
            $similar{$string}{largest} =
                $thisrecord;

            ## Start counting how many times this statement appears
            $similar{$string}{count} = 1;

            ## Store the summary of all sizes so we can compute medians, stddev, etc.
            $similar{$string}{total} = $tempfilesize;


            ## ??Store this away for eventual output
            $find{$filename}{$line} = $similar{$string};
            $find{$filename}{$line}{string} = $string;
            $find{$filename}{$line}{rawstring} = $rawstring;

            ## ??Copy filename and line up a level for later sorting ease
            $find{$filename}{$line}{filename} = $similar{$string}{earliest}{filename};
            $find{$filename}{$line}{line} = $similar{$string}{earliest}{line};
            return 1;

        } ## end if we have not seen this statement before in tempfile mode

        ## We have seen it before, so make some changes

        ## First, increment the count
        $similar{$string}{count}++;

        ## Update our total size
        $similar{$string}{total} += $tempfilesize;

        ## As files are read sequentially, this becomes the latest
        $similar{$string}{latest} = $thisrecord;

        ## If this size is larger than the current record holder, reassign the largest pointer
        if ($tempfilesize > $similar{$string}{largest}{filesize}) {
            $similar{$string}{largest} = $thisrecord;
        }
        ## If this size is smaller than the current record holder, reassign the smallest pointer
        if ($tempfilesize < $similar{$string}{smallest}{filesize}) {
            $similar{$string}{smallest} = $thisrecord;
        }

        return 1;

    } ## end of tempfile mode


  PGPREFIX:
    ## If we have a prefix, check for similar entries
    if (length $pgprefix) {

        ## Seen this string before?
        my $seenit = 0;

        if (exists $similar{$string}) {
            $seenit = 1;
            ## This becomes the new latest one
            $similar{$string}{latest} =
                {
                 filename => $filename,
                 line     => $line,
                 pgprefix => $pgprefix,
                 time     => $time,
                 };
            ## Increment the count
            $similar{$string}{count}++;
        }

        if (!$seenit) {
            ## Store as the earliest and latest version we've seen
            $similar{$string}{earliest} = $similar{$string}{latest} =
                {
                 filename => $filename,
                 line     => $line,
                 pgprefix => $pgprefix,
                 time     => $time,
                 };
            ## Start counting these items
            $similar{$string}{count} = 1;

            ## Store this away for eventual output
            $find{$filename}{$line} = $similar{$string};
            $find{$filename}{$line}{string} = $string;
            $find{$filename}{$line}{rawstring} = $rawstring;

            ## Copy filename and line up a level for later sorting ease
            $find{$filename}{$line}{filename} = $similar{$string}{earliest}{filename};
            $find{$filename}{$line}{line} = $similar{$string}{earliest}{line};
        }
    }
    else {
        $find{$filename}{$line} = {
            string   => $string,
            count    => 1,
            line     => $line,
            filename => $filename,
        };
    }

    return 1;

} ## end of process_line


sub process_report {

    ## No files means nothing to do
    if (! @files_parsed) {
        $arg{quiet} or print qq{No files were read in, exiting\n};
        exit 1;
    }

    ## How many files actually had things?
    my $matchfiles = 0;
    ## How many unique items?
    my $unique_matches = 0;
    for my $f (values %find) {
        $unique_matches += keys %{$f};
    }
    my $pretty_unique_matches = pretty_number($unique_matches);
    ## Which was the latest to contain something?
    my $last_file_parsed;
    for my $file (@files_parsed) {
        next if ! $file->[1];
        $matchfiles++;
        $last_file_parsed = $file->[0];
    }

    my $grand_total = $opt{grand_total};
    my $pretty_grand_total = pretty_number($grand_total);

    ## If not files matched, output the last one processed
    $last_file_parsed = $files_parsed[-1]->[0] if ! defined $last_file_parsed;

    ## Subject with replaced keywords:
    my $subject = $opt{mailsubject} || $DEFAULT_SUBJECT;
    $subject =~ s/FILE/$last_file_parsed/g;
    $subject =~ s/HOST/$hostname/g;
    if ($arg{tsepnosub} or $opt{tsepnosub}) {
        $subject =~ s/NUMBER/$grand_total/g;
        $subject =~ s/UNIQUE/$unique_matches/g;
    }
    else {
        $subject =~ s/NUMBER/$pretty_grand_total/g;
        $subject =~ s/UNIQUE/$pretty_unique_matches/g;
    }

    ## Store the header separate from the body for later size checking
    my @header;

    ## Discourage vacation programs from replying
    push @header => 'Auto-Submitted: auto-generated';
    push @header => 'Precedence: bulk';

    ## Some minor help with debugging
    push @header => "X-TNM-VERSION: $VERSION";

    ## Allow no specific email for dryruns
    if (! exists $opt{email} or ! @{$opt{email}}) {
        if ($arg{dryrun} or $arg{nomail}) {
            push @{$opt{email}} => 'dryrun@example.com'; ## no critic (RequireInterpolationOfMetachars)
        }
    }

    ## Fill out the "To:" fields
    for my $email (@{$opt{email}}) {
        push @header => "To: $email";
    }
    if (! @{$opt{email}}) {
        die "Cannot send email without knowing who to send to!\n";
    }

    my $mailcom = $opt{mailcom} || $arg{mailcom};

    ## Custom From:
    my $from_addr = $opt{from} || '';
    if ($from_addr ne '') {
        push @header => "From: $from_addr";
        $mailcom .= " -f $from_addr";
    }
    ## End header section
    my @msg;

    my $tz = strftime('%Z', localtime());
    my $now = scalar localtime;
    push @msg => "Date: $now $tz";
    push @msg => "Host: $hostname";
    if ($arg{timewarp}) {
        push @msg => "Timewarp: $arg{timewarp}";
    }
    if ($arg{duration} >= 0) {
        push @msg => "Minimum duration: $arg{duration} ms";
    }
    if ($arg{tempfile} >= 0) {
        push @msg => "Minimum tempfile size: $arg{tempfile} bytes";
    }

    if ($arg{type} eq 'normal') {
        push @msg => "Unique items: $pretty_unique_matches";
    }

    ## If we parsed more than one file, label them now
    if ($matchfiles > 1) {
        my $letter = 0;
        push @msg => "Total matches: $pretty_grand_total";
        my $maxcount = 1;
        my $maxname = 1;
        my $maxletter = 1;
        for my $file (@files_parsed) {
            next if ! $file->[1];
            $file->[1] = pretty_number($file->[1]);
            $maxcount = length $file->[1] if length $file->[1] > $maxcount;
            $maxname = length $file->[0] if length $file->[0] > $maxname;
            my $name = chr(65+$letter);
            if ($letter >= 26) {
                $name = sprintf '%s%s',
                    chr(64+($letter/26)), chr(65+($letter%26));
            }
            $letter++;
            $fab{$file->[0]} = $name;
            $maxletter = length $name if length $name > $maxletter;
        }
        for my $file (@files_parsed) {
            next if ! $file->[1];
            my $name = $fab{$file->[0]};
            push @msg => sprintf 'Matches from %-*s %-*s %*s',
                $maxletter + 2,
                "[$name]",
                $maxname+1,
                "$file->[0]:",
                $maxcount,
                $file->[1];
        }
    }
    else {
        push @msg => "Matches from $last_file_parsed: $pretty_grand_total";
    }

    for my $file (@files_parsed) {
        if (exists $toolarge{$file->[0]}) {
            push @msg => "$toolarge{$file->[0]}";
        }
    }

    if ($arg{type} eq 'duration' and $arg{duration_limit} and $grand_total > $arg{duration_limit}) {
        push @msg => "Not showing all lines: duration limit is $arg{duration_limit}";
    }
    if ($arg{type} eq 'tempfile' and $arg{tempfile_limit} and $grand_total > $arg{tempfile_limit}) {
        push @msg => "Not showing all lines: tempfile limit is $arg{tempfile_limit}";
    }

    ## Create the mail message
    my ($bigfh, $bigfile) = tempfile('tnmXXXXXXXX', SUFFIX => '.tnm');

    ## The meat of the message: save to the temporary file
    lines_of_interest($bigfh, $matchfiles);
    print {$bigfh} "\n";

    ## Are we going to need to chunk it up?
    my $filesize = -s $bigfile;
    my $split = 0;
    if ($filesize > $arg{maxemailsize} and ! $arg{dryrun}) {
        $split = 1;
        $arg{verbose} and print qq{File $bigfile too big ($filesize > $arg{maxemailsize})\n};
    }

    my $emails = join ' ' => @{$opt{email}};

    ## Sanity check on number of loops below
    my $safety = 1;

    ## If chunking, which chunk are we currently on?
    my $chunk = 0;

    ## Where in the data file are we starting from?
    my $start_point = 0;
    ## Where in the data file are we going to? 0 means until the end
    my $stop_point = 0;

  LOOP: {

        ## If we are splitting, calculate the new start and stop points
        if ($split) {
            $chunk++;

            ## Start at the old stop point
            $start_point = $stop_point;
            ## Seek up to it, then walk backwards etc.

            seek $bigfh, $start_point + $arg{maxemailsize}, 0;
            my $firstpos = tell $bigfh;
            if ($firstpos >= $filesize) {
                ## We are done!
                $stop_point = 0;
                $split = 0;
            }
            else {
                ## Go backwards a few chunks at a time, see if we can find a good stop point
                ROUND: for my $round (1..10) {
                      seek $bigfh, $firstpos - ($round*5000), 0;

                      ## Only seek forward 10 lines
                      my $lines = 0;

                      while (<$bigfh>) {
                          ## Got a match? Rewind to just before the opening number
                          if ($_ =~ /(.*?)^\[\d/ms) {
                              my $rewind = length($_) - length($1);
                              $stop_point = tell($bigfh) - $rewind;
                              seek $bigfh, $stop_point, 0;
                              if ($start_point >= $stop_point) {
                                  $stop_point = 0;
                                  $split = 0;
                              }
                              last ROUND;
                          }
                          last if $lines++ > 10;
                      }
                      $stop_point = 0;
                      $split = 0;
                  }
            }
        }

        ## Add the subject, adjusting it if needed
        my $newsubject = $subject;
        if ($chunk) {
            $newsubject = "[Chunk $chunk] $subject";
        }

        ## Prepend the header info to our new data file
        my ($efh, $emailfile) = tempfile('tnmXXXXXXXX', SUFFIX => '.tnm2');
        if ($arg{dryrun}) {
            close $efh or warn 'Could not close filehandle';
            $efh = \*STDOUT;
        }
        print {$efh} "Subject: $newsubject\n";
        for (@header) {
            print {$efh} "$_\n";
        }

        ## Stop headers, start the message
        print {$efh} "\n";

        $chunk and print {$efh} "Message was split: this is chunk #$chunk\n";
        for (@msg) {
            print {$efh} "$_\n";
        }
        ## Add a little space before the actual data
        print {$efh} "\n";

        ## Add some subset of the data file to our new temp file
        seek $bigfh, $start_point, 0;

        while (<$bigfh>) {
            print {$efh} $_;
            next if ! $stop_point;
            last if tell $bigfh >= $stop_point;
        }

        ## If we have a signature, add it
        if ($arg{mailsignature}) {
            ## Caller's responsibility to add a "--" line
            print {$efh} $arg{mailsignature};
        }

        close $efh or warn qq{Could not close $emailfile: $!\n};
        
# DEBUG! 
    open my $fh, '<', $emailfile or die qq{Could not open "$emailfile": $!\n};
    open my $debug, '>', './debug.log' or die "Could not open debug.log: $!\n";
    while( <$fh> ) {
        print $debug "$_ \n";
    }
    close $debug;
    close $fh;

        $arg{verbose} and warn "  Sending mail to: $emails\n";
        my $COM = qq{$mailcom '$emails' < $emailfile};
        if ($arg{dryrun} or $arg{nomail}) {
            $arg{quiet} or warn "  DRYRUN: $COM\n";
        }
        else {
            my $mailmode = $opt{mailmode} || $arg{mailmode};
            if ($arg{mailmode} eq 'sendmail') {
                system $COM;
            }
            elsif ($arg{mailmode} eq 'smtp') {
                send_smtp_email($from_addr, $emails, $newsubject, $emailfile);
            }
            else {
                die "Unknown mailmode: $mailmode\n";
            }
        }

        ## Remove our temp file
        unlink $emailfile;

        ## If we didn't split, we are done
        if (! $split) {
            ## Clean up the original data file and leave
            unlink $bigfile;
            return;
        }

        ## Sleep a little bit to not overwhelm the mail system
        sleep 1;

        ## In case of bugs or very large messages, set an upper limit on loops
        if ($safety++ > 5) {
            die qq{Too many loops, bailing out!\n};
        }

        redo;
    }

    ## Clean up the original data file
    unlink $bigfile;

    return;

} ## end of process_report


sub send_smtp_email {

    ## Send email via an authenticated SMTP connection

    ## For Windows, you will need:
    # perl 5.10
    # http://cpan.uwinnipeg.ca/PPMPackages/10xx/
    # ppm install Net_SSLeay.ppd
    # ppm install IO-Socket-SSL.ppd
    # ppm install Authen-SASL.ppd
    # ppm install Net-SMTP-SSL.ppd

    ## For non-Windows:
    # perl-Net-SMTP-SSL package
    # perl-Authen-SASL

    my ($from_addr,$emails,$subject,$tempfile) = @_;

    require Net::SMTP::SSL;

    ## Absorb any values set by rc files, and sanity check things
    my $mailserver = $opt{mailserver} || $arg{mailserver};
    if ($mailserver eq 'example.com') {
        die qq{When using smtp mode, you must specify a mailserver!\n};
    }
    my $mailuser = $opt{mailuser} || $arg{mailuser};
    if ($mailuser eq 'example') {
        die qq{When using smtp mode, you must specify a mailuser!\n};
    }
    my $mailpass = $opt{mailpass} || $arg{mailpass};
    if ($mailpass eq 'example') {
        die qq{When using smtp mode, you must specify a mailpass!\n};
    }
    my $mailport = $opt{mailport} || $arg{mailport};

    ## Attempt to connect to the server
    my $smtp;
    if (not $smtp = Net::SMTP::SSL->new(
        $mailserver,
        Port    => $mailport,
        Debug   => 0,
        Timeout => 30,
    )) {
        die qq{Failed to connect to mail server: $!};
    }

    ## Attempt to authenticate
    if (not $smtp->auth($mailuser, $mailpass)) {
        die 'Failed to authenticate to mail server: ' . $smtp->message;
    }

    ## Prepare to send the message
    $smtp->mail($from_addr) or die 'Failed to send mail (from): ' . $smtp->message;
    $smtp->to($emails)      or die 'Failed to send mail (to): '   . $smtp->message;
    $smtp->data()           or die 'Failed to send mail (data): ' . $smtp->message;
    ## Grab the lines from the tempfile and pipe it on to the server
    open my $fh, '<', $tempfile or die qq{Could not open "$tempfile": $!\n};
    while (<$fh>) {
        $smtp->datasend($_);
    }
    close $fh or warn qq{Could not close "$tempfile": $!\n};
    $smtp->dataend() or die 'Failed to send mail (dataend): ' . $smtp->message;
    $smtp->quit      or die 'Failed to send mail (quit): '    . $smtp->message;

    return;

} ## end of send_smtp_email


sub lines_of_interest {

    ## Given a file handle, print all our current lines to it

    my ($lfh,$matchfiles) = @_;

    my $oldselect = select $lfh;

    our ($current_filename, %sorthelp);
    undef %sorthelp;

    sub sortsub { ## no critic (ProhibitNestedSubs)

        my $sorttype = $opt{sortby} || $arg{sortby};

        if ($arg{type} eq 'duration') {
            if (! exists $sorthelp{$a}) {
                my $lstring = $a->{string} || $a->{earliest}{string};
                $sorthelp{$a} =
                    $lstring =~ /duration: (\d+\.\d+)/o ? $1 : 0;
            }
            if (! exists $sorthelp{$b}) {
                my $lstring = $b->{string} || $b->{earliest}{string};
                $sorthelp{$b} =
                    $lstring =~ /duration: (\d+\.\d+)/o ? $1 : 0;
            }
            return ($sorthelp{$b} <=> $sorthelp{$a})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        ## For tempfile, we want to sort by largest overall tempfile
        ## In a tie, we do the highest mean, count, filename, then line number!
        elsif ($arg{type} eq 'tempfile') {
            return ($b->{largest}{filesize} <=> $a->{largest}{filesize})
                    || $b->{mean} <=> $a->{mean}
                    || $b->{count} <=> $a->{count}
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        ## Special sorting for the display of means
        elsif ($arg{type} eq 'tempfilemean') {
            return ($b->{mean} <=> $a->{mean})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        ## Special sorting for the display of means
        elsif ($arg{type} eq 'tempfiletotal') {
            return ($b->{total} <=> $a->{total})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        elsif ($sorttype eq 'count') {
            return ($b->{count} <=> $a->{count})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        elsif ($sorttype eq 'date') {
            return ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                || ($a->{line} <=> $b->{line});

        }

        return $a <=> $b;
    }

    ## Flatten the items for ease of sorting
    my @sorted;
    for my $f (keys %find) {
        for my $l (keys %{$find{$f}}) {
            push @sorted => $find{$f}{$l};
        }
    }

    ## If we are in tempfile mode, perform some statistics
    if ($arg{type} eq 'tempfile') {

        for my $row (@sorted) {
            $row->{mean} = int ($row->{total} / $row->{count});
            ## Mode is meaningless, median too hard to compute
        }

        my $totalitems = @sorted;

        ## We want to show the top X means

        ## Assign our numbers so we can display the list of means
        my $count = 0;
        for my $f (sort sortsub @sorted) {
            $count++;
            $f->{displaycount} = $count;
        }

        ## Gather the means
        my @mean;
        $arg{type} = 'tempfilemean'; ## Trickery
        my $maxmean = 0;
        my $meancount = 0;
        for my $f (sort sortsub @sorted) {
            $meancount++;
            my $item = sprintf '(item %d, count is %d)', $f->{displaycount}, $f->{count};
            push @mean => sprintf '%10s %-22s', pretty_size($f->{mean},1), $item;
            $maxmean = $f->{displaycount} if $f->{displaycount} > $maxmean;
            last if $arg{tempfile_limit} and $meancount >= $arg{tempfile_limit};
        }

        ## Gather the totaltemp
        my @totaltemp;
        $arg{type} = 'tempfiletotal';
        my $maxtotal = 0;
        my $totalcount = 0;
        for my $f (sort sortsub @sorted) {
            $totalcount++;
            my $item = sprintf '(item %d, count is %d)', $f->{displaycount}, $f->{count};
            push @totaltemp => sprintf '%10s %-22s', pretty_size($f->{total},1), $item;
            $maxtotal = $f->{displaycount} if $f->{displaycount} > $maxtotal;
            last if $arg{tempfile_limit} and $totalcount >= $arg{tempfile_limit};
        }
        $arg{type} = 'tempfile';

        ## Print out both the mean and the total
        print "  Top items by arithmetic mean    |   Top items by total size\n";
        print "----------------------------------+-------------------------------\n";
        $count = 0;
        {
            last if ! defined $mean[$count] and ! defined $totaltemp[$count];
            printf '%-s |', defined $mean[$count] ? $mean[$count] : '';
            printf "%s\n", defined $totaltemp[$count] ? $totaltemp[$count] : '';
            $count++;
            redo;
        }

        ## Set a new tempfile_limit based on how many mean entries we found above
        if ($maxmean > $arg{tempfile_limit}) {
            $arg{tempfile_limit} = $maxmean;
        }
        if ($maxtotal > $arg{tempfile_limit}) {
            $arg{tempfile_limit} = $maxtotal;
        }

    } ## end of tempfile mode

    my $count = 0;
    for my $f (sort sortsub @sorted) {

        $count++;

        if ($arg{find_line_number}) {
            $f->{line} = pretty_number($f->{line});
        }

        last if $arg{showonly} and $count > $arg{showonly};

        ## Sometimes we don't want to show all the durations
        if ($arg{type} eq 'duration' and $arg{duration_limit}) {
            last if $count > $arg{duration_limit};
        }

        ## Sometimes we don't want to show all the tempfiles
        if ($arg{type} eq 'tempfile' and $arg{tempfile_limit}) {
            last if $count > $arg{tempfile_limit};
        }

        print "\n[$count]";

        my $filename = exists $f->{earliest} ? $f->{earliest}{filename} : $f->{filename};

        ## If only a single entry, simpler output
        if ($f->{count} == 1 and $arg{hideflatten}) {
            if ($matchfiles > 1) {
                printf " From file %s%s\n",
                    $fab{$filename},
                    $arg{find_line_number} ? " (line $f->{line})" : '';
            }
            elsif ($arg{find_line_number}) {
                print " (from line $f->{line})\n";
            }
            else {
                print "\n";
            }

            ## If in tempfile mode, show the prettified information here
            if ($arg{type} eq 'tempfile') {
                printf "Temp file size: %s\n", pretty_size($f->{largest}{filesize});
            }

            ## If we are using prefixes, show it here
            if (exists $f->{earliest}{pgprefix}) {
                print "$f->{earliest}{pgprefix}\n";
            }

            ## Show the actual string, not the flattened version
            my $lstring = wrapline($f->{rawstring} || $f->{string});
            print "$lstring\n";

            next;
        }

        ## More than one entry means we have an earliest and latest to look at
        my $earliest = $f->{earliest};
        my $latest = $f->{latest};
        my $pcount = pretty_number($f->{count});

        if ($arg{find_line_number}) {
            $latest->{line} = pretty_number($latest->{line});
        }

        ## Does it span multiple files?
        my $samefile = $earliest->{filename} eq $latest->{filename} ? 1 : 0;
        if ($samefile) {
            if ($matchfiles > 1) {
                print " From file $fab{$filename}";
                if ($arg{find_line_number}) {
                    print " (between lines $f->{line} and $latest->{line}, occurs $pcount times)";
                }
                else {
                    print " Count: $f->{count}";
                }
                print "\n";
            }
            else {
                if ($arg{find_line_number}) {
                    print " (between lines $f->{line} and $latest->{line}, occurs $pcount times)";
                }
                else {
                    print " Count: $pcount";
                }
                print "\n";
            }
        }
        else {
            my ($A,$B) = ($fab{$earliest->{filename}}, $fab{$latest->{filename}});
            print " From files $A to $B";
            if ($arg{find_line_number}) {
                printf " (between lines $f->{line} of $A and $latest->{line} of $B, occurs $pcount times)",;
            }
            else {
                print " Count: $pcount";
            }
            print "\n";
        }

        if ($arg{type} eq 'tempfile') {

            ## If there was more than one, show some summary information
            if ($f->{count} > 1) {
                printf "Arithmetic mean is %s, total size is %s\n",
                    pretty_size($f->{mean}), pretty_size($f->{total});
            }

            ## Show the exact size, or the smallest and largest if both available
            if ($f->{smallest}{filesize} == $f->{largest}{filesize}) {
                printf "Temp file size: %s\n", pretty_size($f->{largest}{filesize});
            }
            else {
                ## Show the smallest and the largest temp files used for this statement
                ## Show the prefix (e.g. timestamp) when it occurred if available

                my $s = $f->{smallest};
                printf "Smallest temp file size: %s%s\n",
                    pretty_size($s->{filesize}),
                    (exists $s->{pgprefix} and $s->{pgprefix} ne '?') ? " ($s->{pgprefix})" : '';

                my $l = $f->{largest};
                printf "Largest temp file size: %s%s\n",
                    pretty_size($l->{filesize}),
                    (exists $l->{pgprefix} and $l->{pgprefix} ne '?') ? " ($l->{pgprefix})" : '';
            }
        }

        ## If we have prefixes available, show those
        my $estring = $f->{string};
        if (exists $earliest->{pgprefix}) {
            if ($earliest->{pgprefix} ne '?') { ## Skip direct lines
                printf "First: %s%s\nLast:  %s%s\n",
                    $samefile ? '' : "[$fab{$earliest->{filename}}] ",
                    $earliest->{pgprefix},
                    $samefile ? '' : "[$fab{$latest->{filename}}] ",
                    $latest->{pgprefix};
            }
            $estring =~ s/^\s+//o;
            print wrapline($estring);
            print "\n";
        }
        else {
            print " Earliest and latest:\n";
            print wrapline($estring);
            print "\n";
            print wrapline($latest->{string});
            print "\n";
        }

        ## Show the first actual error if we've flattened things out
        if ($estring ne $f->{rawstring}) {
            print "-\n";
            print wrapline($f->{rawstring});
            print "\n";
        }

    } ## end each item

    select $oldselect;

    return;

} ## end of lines_of_interest


sub wrapline {

    ## Truncate lines that are too long
    ## Wrap long lines to make SMTP servers happy

    my $line = shift;

    my $len = length $line;
    my $olen = $len;
    my $waschopped = 0;
    my $maxsize = defined $opt{statement_size}
        ? $opt{statement_size}
        : $arg{statement_size};

    if ($maxsize and $len > $maxsize) {
        $line = substr($line,0,$maxsize);
        $waschopped = 1;
        $len = $maxsize;
    }

    if ($len >= $WRAPLIMIT) {
        $line =~ s{(.{$WRAPLIMIT})}{$1\n}g;
    }

    if ($waschopped) {
        $olen = pretty_number($olen);
        $line .= "\n[LINE TRUNCATED, original was $olen characters long]";
    }

    return $line;

} ## end of wrapline


sub final_cleanup {

    $arg{debug} and warn "  Performing final cleanup\n";

    ## Need to walk through and see if anything has changed so we can rewrite the config
    ## For the moment, that only means the offset and the lastfile

    ## Have we got new lastfiles or offsets?
    for my $t (@{ $opt{file} }) {
        if( $t->{latest} && $t->{lastfile} && ($t->{latest} ne $t->{lastfile}) ) {
            $changes++;
            $t->{lastfile} = delete $t->{latest};
        }
        if (exists $opt{newoffset}{$t->{lastfile}}) {
            my $newoffset = $opt{newoffset}{$t->{lastfile}};
            if ($t->{offset} != $newoffset) {
                $changes++;
                $t->{offset} = $newoffset;
            }
        }
    }

    ## No rewriting if in dryrun mode, but reset always trumps dryrun
    ## Otherwise, do nothing if there have been no changes
    return if (!$changes or $arg{dryrun}) and !$arg{reset};

    $arg{verbose} and warn "  Saving new config file\n";
    open my $fh, '>', $configfile or die qq{Could not write "$configfile": $!\n};
    my $oldselect = select $fh;
    my $now = localtime;
    print qq{## Config file for the tail_n_mail program
## This file is automatically updated
## Last updated: $now
};

    for my $item (qw/ log_line_prefix email from type mailsig duration tempfile find_line_number sortby duration_limit tempfile_limit/) {
        next if ! exists $opt{$item};

        next if $item eq 'duration' and $arg{duration} < 0;
        next if $item eq 'duration_limit' and ! $arg{duration_limit};

        next if $item eq 'tempfile' and $arg{tempfile} < 0;
        next if $item eq 'tempfile_limit' and ! $arg{tempfile_limit};

        ## Only rewrite if it came from this config file, not tailnmailrc or command line
        next if ! exists $opt{configfile}{$item};
        add_comments(uc $item);
        if (ref $opt{$item} eq 'ARRAY') {
            for my $itemz (@{$opt{$item}}) {
                next if ! exists $opt{configfile}{"$item.$itemz"};
                printf "%s: %s\n", uc $item, $itemz;
            }
        }
        else {
            ## If it has leading or trailing whitespace, quote it
            if ($opt{$item} =~ /^\s/ or $opt{$item} =~ /\s$/) {
                printf qq{%s: "%s"\n}, uc $item, $opt{$item};
            }
            else {
                printf "%s: %s\n", uc $item, $opt{$item};
            }
        }
    }

    if ($opt{configfile}{maxsize}) {
        print "MAXSIZE: $opt{maxsize}\n";
    }
    if ($opt{customsubject}) {
        add_comments('MAILSUBJECT');
        print "MAILSUBJECT: $opt{mailsubject}\n";
    }

    print "\n";
    for my $inherit (@{$opt{inherit}}) {
        add_comments("INHERIT: $inherit");
        print "INHERIT: $inherit\n";
    }
    for my $include (@{$opt{include}}) {
        next if ! exists $opt{configfile}{"include.$include"};
        add_comments("INCLUDE: $include");
        print "INCLUDE: $include\n";
    }
    for my $exclude (@{$opt{exclude}}) {
        next if ! exists $opt{configfile}{"exclude.$exclude"};
        add_comments("EXCLUDE: $exclude");
        print "EXCLUDE: $exclude\n";
    }
    for my $exclude_prefix (@{$opt{exclude_prefix}}) {
        next if ! exists $opt{configfile}{"exclude_prefix.$exclude_prefix"};
        add_comments("EXCLUDE_PREFIX: $exclude_prefix");
        print "EXCLUDE_PREFIX: $exclude_prefix\n";
    }
    for my $exclude_non_parsed (@{$opt{exclude_non_parsed}}) {
        next if ! exists $opt{configfile}{"exclude_non_parsed.$exclude_non_parsed"};
        add_comments("EXCLUDE_NON_PARSED: $exclude_non_parsed");
        print "EXCLUDE_NON_PARSED: $exclude_non_parsed\n";
    }

    print "\n";
    add_comments('FILE');
    for my $f (sort { $a->{suffix} <=> $b->{suffix} }
               @{ $opt{file} }) {

        ## Skip inherited files
        next if exists $f->{inherited};

        printf "\nFILE%d: %s\n", $f->{suffix}, $f->{original};

        ## Got any lastfile or offset for these?
        if ($f->{lastfile}) {
            printf "LASTFILE%d: %s\n", $f->{suffix}, $f->{lastfile};
        }
        ## The offset may be new, or we may be the same as last time
        if (exists $opt{newoffset}{$f->{lastfile}}) {
            printf "OFFSET%d: %d\n", $f->{suffix}, $opt{newoffset}{$f->{lastfile}};
        }
        elsif ($f->{offset}) {
            printf "OFFSET%d: %d\n", $f->{suffix}, $f->{offset};
        }
    }
    print "\n";

    select $oldselect;
    close $fh or die qq{Could not close "$configfile": $!\n};

    return;

} ## end of final_cleanup


sub add_comments {

    my $item = shift;
    return if ! exists $itemcomment{$item};
    for my $comline (@{$itemcomment{$item}}) {
        print $comline;
    }

    return;

} ## end of add_comments


sub pretty_number {

    ## Format a raw number in a more readable style

    my $number = shift;

    return $number if $number !~ /^\d+$/ or $number < 1000;

    ## If this is our first time here, find the correct separator
    if (! defined $arg{tsep}) {
        my $lconv = localeconv();
        $arg{tsep} = $lconv->{thousands_sep} || ',';
    }

    ## No formatting at all
    return $number if '' eq $arg{tsep} or ! $arg{tsep};

    (my $reverse = reverse $number) =~ s/(...)(?=\d)/$1$arg{tsep}/g;
    $number = reverse $reverse;
    return $number;

} ## end of pretty_number


sub pretty_size {

    ## Transform number of bytes to a SI display similar to Postgres' format

    my $bytes = shift;
    my $rounded = shift || 0;

    return "$bytes bytes" if $bytes < 10240;

    my @unit = qw/kB MB GB TB PB EB YB ZB/;

    for my $p (1..@unit) {
        if ($bytes <= 1024**$p) {
            $bytes /= (1024**($p-1));
            return $rounded ?
                sprintf ('%d %s', $bytes, $unit[$p-2]) :
                    sprintf ('%.2f %s', $bytes, $unit[$p-2]);
        }
    }

    return $bytes;

} ## end of pretty_size



__DATA__

## Example config file:

## Config file for the tail_n_mail program
## This file is automatically updated
EMAIL: someone@example.com
MAILSUBJECT: Acme HOST Postgres errors UNIQUE : NUMBER

FILE: /var/log/postgres-%Y-%m-%d.log
INCLUDE: ERROR:  
INCLUDE: FATAL:  
INCLUDE: PANIC:  
