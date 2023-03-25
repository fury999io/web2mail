#!/usr/bin/perl -T
# grab-url-from-mail.plx                                          -*- Perl -*-

# To use this script you must add something like this to your
# /etc/aliases file:
#
#   wget: "|/location/of/grab-url-from-mail.plx"
#   owner-wget: bug-handler@foo.org
#
# You will also have to create the configuration file
# `/etc/grab-url-from-mail.conf' that contains (atleast) the
# following:
#
#   @Config::validFrom = ('user00@foo.org', 'user01@foo.org');
#   $Config::fromAddr = 'wget@foo.org';
#   $Config::ownerAddr = 'owner-wget@foo.org';
#
# Then user00@foo.org and user01@foo.org can send a email to
# wget@foo.org, with subject the subject "wget URL".
#
# The address `bug-handler@foo.org' should point to the person, or
# persons who are responsible for the script.
#
# Don't forget to add the email addresses that are allowed to use this
# script to validFrom.

use strict;
use warnings;
no warnings 'once';

use LWP::UserAgent;
use File::MMagic;
use File::Basename;
use Convert::UU 'uuencode';

my $config_file = dirname($0) . "/grab-url-from-mail.conf";
do $config_file or die $@;

###############################################################################
%ENV = ();
my $SENDMAIL = "/usr/lib/sendmail -f $Config::fromAddr -oi -t";

###############################################################################
sub MailError (@) {
  my (@data) = @_;

  open(SENDMAIL,  "| $SENDMAIL") || die "unable to run $SENDMAIL: $!";

  print SENDMAIL @data;

  close SENDMAIL;
  sleep 2;

  die "error running $SENDMAIL: $!" unless ($? == 0);

  return $?;
}
###############################################################################
sub InvalidUser (\@$) {
  my ($message, $exitCode) = @_;

  my $str = <<INVALID_USER;
To: $Config::ownerAddr
From: $Config::fromAddr
Subject: wget: $Config::fromAddr: invalid user access

An invalid user attempted to access $Config::fromAddr.  Below is the full
message that the wget daemon script received.

INVALID_USER

 exit MailError($str, @{$message});

#  exit $exitCode;
}
###############################################################################
sub InvalidURL(\@$$$) {
  my ($message, $url, $returnAddress,  $exitCode) = @_;

  my $str = <<INVALID_URL;
To: $Config::ownerAddr
Cc: $returnAddress
From: $Config::fromAddr
Subject: wget: $Config::fromAddr: invalid URL sent

The user, $returnAddress, has sent an invalid URL to the wget daemon.  The
URL will not be processed.  If this message is in error, please ask
<$Config::ownerAddr> to repair the script.  The URL sent was:
  $url

Below is the full message that the wget daemon script received.
INVALID_URL

 exit MailError($str, @{$message});

#  exit $exitCode;
}
###############################################################################
sub MiscError(\@$$$) {
  my ($message, $error, $returnAddress, $exitCode) = @_;

  my $str = <<MISC_ERROR;
To: $Config::ownerAddr
Cc: $returnAddress
From: $Config::fromAddr
Subject: wget $Config::fromAddr: unknown error

The user, $returnAddress, has requested an URL from the wget daemon.
The URL could not be processed.  If this message is in error, please ask
<$Config::ownerAddr> to repair the script.  The Error message was:
  $error

Below is the full message that the wget daemon script received.
MISC_ERROR

  exit MailError($str, @{$message});

#  exit $exitCode;
}
###############################################################################

my($returnAddress, $url);
my @fullMessage;
my $headerDone = 0;

while (my $line = <>) {
  push @fullMessage, $line;

  $headerDone = 1 if $line =~ /^\s*$/;

  next if $headerDone;
  chomp $line;

  if ($line =~ /^(?:From|Reply-To):/) {
    next if ($line =~ /^From:/ and defined $returnAddress);
    foreach my $validFrom (@Config::validFrom) {
      $returnAddress = $validFrom if ($line =~ /$validFrom/);
    }
  } elsif ($line =~ /^Subject:\s*wget\s*(.+?)\s*$/i) {
    $url = $1;
  }
  last if defined $url and defined $returnAddress;
}

# Make sure we are responding to a known user
InvalidUser(@fullMessage, 2) unless defined $returnAddress;

# Check for URL validity.
InvalidURL(@fullMessage, " NO WGET LINE FOUND IN SUBJECT", $returnAddress, 2)
  unless (defined $url);


# This bit is not needed, since LWP handles all escaping
# InvalidURL(@fullMessage, $url, $returnAddress, 2)
#  unless ($url =~ m%^[\@\w\-\+\.,\'\"\/\&\#:\?\_\%\~\=\(\)]+$%);


# Grab the URL contents.

# Set max_redirect to something high and enable cookies (cookie_jar)
# so that we work across redirects properly in a single session (some
# sites, nytimes.com depend on this behaviour). -- ams, 2008-07-07

my $ua = LWP::UserAgent->new(agent => "Mozilla/5.0 (compatible)",
                             env_proxy => 0, keep_alive => 1,
                             timeout   => 30,
			     max_redirect => 15, cookie_jar => {},
			     protocols_allowed => ['http', 'https', 'gopher', 'ftp']);

# Some web-sites (e.g. http://www.keionline.org/blogs/) run a server
# side program called `Bad Behaviour' (BB), which is supposed to stop
# spam-, and harversting-bots.  By pusshing headers that seem to be
# something that a normal web browser would pass, we (hopefully) get
# around BB's checks. -- ams, 2009-06-27
$ua->default_headers->push_header('Accept' => '*/*');

my $response = $ua->get($url);
my $urlData = $response->content();


# Send contents back to the requesting party.

open(SENDMAIL,  "| $SENDMAIL") or
  MiscError(@fullMessage, "cannot run $SENDMAIL: $!", $returnAddress, $@);

my $file = $url;
$file =~ s%^\s*\S+/([^/]+)\s*$%$1%; # Extract the file name part of a URL.
$file =~ s%\s*%$1%;		    # No spaces in file names.

my $mm = File::MMagic->new();

my $mime = $mm->checktype_contents($urlData);

# Check to see if the file is some form of text. Otherwise, we
# uuencode it.

my $decodeline;

# We need to quote FILE when outputting, since it can contain strange
# characters (e.g. &); this could lead to strange errors when
# executing the script that follows. -- ams, 2008-07-07
if ($mime =~ /text/) {
  $decodeline = "cat << \'!EOF!-$file\' > \'$file\'";
} else {
  $decodeline = "cat << \'!EOF!-$file\' | uudecode -o \'$file\'";
  $urlData = uuencode($urlData);
}

# Check if the user supplied address is the same as the one we fetched
# from, if not mention that we got redirected to the user.  Some
# websites, specially URL shortening ones (e.g. http://bit.ly/) do
# this kind of redirection.  -- ams, 2010-01-17
#
# Notes for posterity:
#   $response->base -- returns only base part of URI.
#   $response->filename -- returns only file name part of URI.
#
#   -- ams, 2011-03-13
my $urlBase = $response->request->uri;
my $urlMsg = "";
if ($url ne $urlBase) {
    $urlMsg = "The URL\n  $url\nwas redirected to\n  $urlBase\n";
}

print SENDMAIL <<HEADER;
To: $returnAddress
From: $Config::fromAddr
Reply-To: $returnAddress
Subject: wget: retrieved $url

$urlMsg

Please report bugs to <$Config::ownerAddr>.

#!/bin/sh
# 1 files: \'$file\' ($mime)
$decodeline
HEADER

print SENDMAIL "$urlData\n";

print SENDMAIL <<FOOTER;
!EOF!-$file
exit 0
FOOTER

close(SENDMAIL);
#sleep 2;

MiscError(@fullMessage, "$SENDMAIL run failed: $!", $returnAddress, $@)
  unless ($? == 0);

exit $?;
###############################################################################
# Local variables:
# compile-command: "perl -c grab-url-from-mail.plx"
# End:
