#!/bin/bash

GUFM_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64;rv:42.0) Gecko/20100101 Firefox/42.0";
# max mail lines to be saved.
GUFM_MAX_MESSAGE_LINES=32;
# max allowed mail line length.
GUFM_MAX_MESSAGE_LINE_LENGTH=256;

GUFM_LOG_FILE="/home/a/ams/hacks/gufm.log";
GUFM_DEBUG=1;

GUFM_CONFIG_FILE="/home/a/ams/grab-url-from-mail-alpha.conf";
if [ ! -e ${GUFM_CONFIG_FILE} ]; then
    echo "${GUFM_CONFIG_FILE}: file not found"
    exit 1
fi
. "${GUFM_CONFIG_FILE}";

MESSAGE_ID=""; # filled later, se below.
# misc functions
function l() {
 local timestamp;
 local host;

 [ "${GUFM_DEBUG}" == "1" ] || return 0;

 timestamp=`date`;
 host=${HOSTNAME:-"localhost"};

 echo "${timestamp} ${host}${MESSAGE_ID} gufm:${FUNCNAME[1]}:${BASH_LINENO[0]} $*" >> "${GUFM_LOG_FILE}";
}

function gufm_cleanup() {
 rm -f "${tmpfile}" "${tmp_message}" "${newtmpfile}";
}

trap gufm_cleanup EXIT SIGHUP SIGQUIT SIGINT SIGTERM SIGKILL;

for sender in "${!GUFM_ALLOWED_SENDERS[@]}"; do
 l "loaded allowed sender: '$sender'.";
done

function gufm_is_allowed() {
 local sender="$1";
 local is_allowed="0";

 [ "${sender}" == "" ] && { l "empty sender"; return 0; }

 if [[ $sender =~ \<.*\> ]]; then
  # support for 'From: Long Name <email@address.org>'
  sender=`echo "$sender" | sed -e 's/.*<\([^>]*\)>.*/\1/'`;
 elif [[ $sender =~ \(.*\) ]]; then
  # support for 'From: email@address.org (Long Name)'
  sender=`echo "$sender" | awk '{ print($1); }'`;
 fi;
 # otherwise we just take the whole From to match.

 # this repeated check basically checks for malformed From: fields
 # in case above conditions kicked in and From: contained e.g.: <>
 [ "${sender}" == "" ] && { l "empty sender"; return 0; }
 is_allowed=${GUFM_ALLOWED_SENDERS["${sender}"]};
 [ "${is_allowed}" == "1" ] && { l "welcome '${sender}'"; return 0; }
 l "'${sender}' disallowed.";
 return 1;
}

function gufm_bad_url() {
 local f="${1}";
 local url="${2}";
 local full_message="${3}";
 local eof;

 [ "${f}" != "" ] || return 1;
 [ "${url}" != "" ] || return 1;
 [ "${full_message}" != "" ] || return 1;
 eof=EOM-`mktemp -u | cut -f2 -d.`;
 cat <<${eof} | /usr/lib/sendmail -f ${GUFM_SEND_FROM} -oi -t 2>/dev/null
To: ${GUFM_OWNER_ADDRESS}
Cc: $f
From: ${GUFM_SEND_FROM}
Subject: Invalid URL sent to $f

The user, $f, has sent an invalid URL to the wget daemon.  The
URL will not be processed.  If this message is in error, please ask
<${GUFM_OWNER_ADDRESS}> to repair the script.  The URL sent was:
  $url

Below is the full message that the wget daemon script received.
`cat "${full_message}"`

cheers,
gufm

${eof}
}

function gufm_sender_not_allowed() {
 local f="${1}";
 local url="${2}";
 local full_message="${3}";
 local eof;

 eof=EOM-`mktemp -u | cut -f2 -d.`;
 cat <<${eof} | /usr/lib/sendmail -f ${GUFM_SEND_FROM} -oi -t 2>/dev/null
To: ${GUFM_OWNER_ADDRESS}
From: ${GUFM_SEND_FROM}
Subject: Invalid user accessing ${GUFM_SEND_FROM}

An invalid user attempted to access ${GUFM_SEND_FROM}.  Below is the full
message that the wget daemon script received.

Below is the full message that the wget daemon script received.
`cat "${full_message}"`

cheers,
gufm

${eof}
}

function gufm_parse_from() {
 echo "${1}" | sed -e 's/^From: //';
}

function gufm_parse_url() {
 [[ ${1} =~ ^Subject:.*wget ]] || return 1;
 echo "${1}" | sed -e 's/^Subject:.*wget //';
}

function gufm_validate_url() {
 local url="${1}";
 
 [ "${url}" != "" ] || return 1;
 [[ ${url} =~ ^[a-zA-Z/\.@:\?\=\+\&0-9%-]*$ ]] || return 2;
 return 0;
}

tmp_message=`mktemp`;
url="";
from="";
subject="";
line=0;
l "tmp_message: ${tmp_message}";
while read; do
 [ ${#REPLY} -ge $GUFM_MAX_MESSAGE_LINE_LENGTH ] && { l "maximum size of line exceeded in mail message (From: '${from}')."; exit 1; };
 l "got: '${REPLY}'";
 echo "${REPLY}" >> "${tmp_message}";
 [ "${REPLY}" == "" ] && continue; # skip empty lines
 first_word=`echo "${REPLY}" | cut -f1 -d' '`;
 # in the following we are only interested in Subject:, From:, Reply-To:
 [ "${first_word}" != "Reply-To:" ] && [ "${first_word}" != "From:" ]  && [ "${first_word}" != "Subject:" ] && [ "${first_word}" != "Message-Id:" ] && continue;
 [ "${first_word}" == "Message-Id:" ] && MESSAGE_ID="(${REPLY})";
 [ "${first_word}" == "Reply-To:" ] && from=`gufm_parse_from "${REPLY}"`;
 [ "${from}" == "" ] && [ "${first_word}" == "From:" ] && from=`gufm_parse_from "${REPLY}"`;
 [ "${first_word}" == "Subject:" ] && { subject="${REPLY}"; url=`gufm_parse_url "${REPLY}"`; };
 let line++;
 [ $line -ge $GUFM_MAX_MESSAGE_LINES ] && { l "mail message exceeds max lines count ($GUFM_MAX_MESSAGE_LINES)"; exit 1; };
done;

[ "${url}" == "" ] && { l "cant parse url (From: '${from}' Subject: '${Subject}'). exiting."; exit 1; };
[ "${from}" == "" ] && { l "cant find From: field. exiting."; exit 1; };

# gufm_validate_from "${from}" || exit 2;
gufm_validate_url "${url}" || {  l "bad url (From: '${from}' Subject: '${subject}' url: '${url}'). exiting."; gufm_bad_url "${from}" "${url}" "${tmp_message}"; exit 3; };

l "from: ${from}; url: ${url};"
gufm_is_allowed "${from}" || { gufm_sender_not_allowed "${from}" "${url}" "${tmp_message}"; exit 1; };

tmpfile=`mktemp`;
l "saving into '${tmpfile}'";
url_effective=`curl -s -k -L -w '%{url_effective}' -X GET -H "User-Agent: ${GUFM_USER_AGENT}" -o "${tmpfile}" "${url}"`;
l "curl rc=$?";

file="foo";
mime=`file -b --mime-type "${tmpfile}"`;
if ! [[ ${mime} =~ ^text ]] && ! [[ ${mime} =~ ^html ]]; then
 newtmpfile=`mktemp`;
 uuencode "${tmpfile}" "${file}.bin" > "${newtmpfile}";
 rm -f "${tmpfile}";
 tmpfile="${newtmpfile}";
 l "uuencoded into '${tmpfile}'";
 decode_line="cat << '_EOF_-${file}.bin' | uudecode -o '${file}.bin'";
 decode_eof="_EOF_-${file}.bin";
else
 decode_line="cat << '_EOF_-${file}.html' > '${file}.html'";
 decode_eof="_EOF_-${file}.html";
fi;

url_message=""
if [ "${url}" != "${url_effective}" ]; then
    url_message="The URL
   ${url}
was redirected to
  ${url_effective}
"
fi

cat <<EOM | /usr/lib/sendmail -f ${GUFM_SEND_FROM} -oi -t 2>/dev/null
To: ${from}
From: ${GUFM_SEND_FROM}
Reply-To: ${from}
Content-Type: text/plain; charset=us-ascii
Subject: wget: 1 files retrieved with wget $url

${url_message}

Please report bugs to ${GUFM_OWNER_ADDRESS}.

#!/bin/sh
# 1 files: \'$file\' ($mime)
$decode_line
`cat "${tmpfile}"`

$decode_eof

cheers,
gufm

EOM
l "sending back rc=$?";


