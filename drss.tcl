#######################################################################
#                                                                     #
# rssnews.tcl - RSS news announcer for eggdrop by demond@demond.net   #
#                                                                     #
#               this will announce the updated news from RSS feed(s), #
#               periodically polling the feed(s); supports multiple   #
#               channels/multiple feeds per channel; you only need to #
#               set up your feeds array, see below; secure (SSL) and  #
#               private (password-protected) feeds are also supported #
#                                                                     #
#        Usage: !news <feed name> [news index #] - from channel       # 
#               .rss <add|del|list> [name:#chan] - from partyline     #
#                                                                     #
#######################################################################

package require Tcl 8.3
package require eggdrop 1.6
package require http 2.0

namespace eval rssnews {

# set your feed(s) sources here: feed name, channel, poll frequency in mins, feed URL
#
#set feeds(osnews:#chan1) {17 http://www.osnews.com/files/recent.rdf}
#set feeds(google:#chan2) {11 http://news.google.com/news?ned=us&topic=h&output=rss}
#
# if you have to use password-protected feed, set it up like this:
#
#set feeds(name3:#chan3) {13 http://some.site.com/feed username password}

# maximum number of announced new headlines
#
variable maxnew 5

# feed fetch timeout in seconds
#
variable timeout 20

# public trigger flood settings
#
variable pubflud 5:15

# support SSL feeds (requires TLS package)
#
variable usessl 0

# if usessl is 1, request/require valid certificate from server
#
variable reqcert yes:no

#######################################################################
# nothing to edit below

variable version "rssnews-2.2"

if {$usessl} {
	package require tls 1.5
	scan $reqcert {%[^:]:%s} r1 r2
	if {$r1 == "yes"} {set r1 1} {set r1 0}
	if {$r2 == "yes"} {set r2 1} {set r2 0}
	set ssl [list ::tls::socket -request $r1 -require $r2]
	::http::register https 443 $ssl
}

bind dcc  m rss   [namespace current]::rss
bind pub  - !news [namespace current]::news
bind time - *     [namespace current]::timer

putlog "$version by demond loaded"

proc timer {min hour day month year} {
	variable feeds
	if {[info exists feeds]} {
	set mins [expr [scan $min %d]+[scan $hour %d]*60]
	foreach {chanfeed settings} [array get feeds] {		
		if {$mins % [lindex $settings 0] == 0} {
			if {[llength $settings] > 2} {
				foreach {t url user pass} $settings {break} 
				fetch $url $chanfeed $user $pass
			} {
				foreach {t url} $settings {break}
				fetch $url $chanfeed
			}
		}
	}}
}

proc fetch {url chanfeed args} {
	variable timeout
	variable version; variable token
	set to [expr {$timeout * 1000}]
	set cmd [namespace current]::callback
	if {[llength $args] > 0} {
		foreach {user pass} $args {break}
		set hdr [list Authorization "Basic [b64en $user:$pass]"]
	} {	set hdr {}}
	::http::config -useragent "$version by demond"
	if {[catch {set t [::http::geturl $url -command $cmd -timeout $to -headers $hdr]} err]} {
		putlog "$version: ERROR($chanfeed): $err"
	} {
		set token($t) [list $url $chanfeed $args]
	}
}

proc callback {t} {
	variable version; variable token
	foreach {url chanfeed args} $token($t) {break}
	switch -exact [::http::status $t] {
	"timeout" {
		putlog "$version: ERROR($chanfeed): timeout"
	}
	"error" {
		putlog "$version: ERROR($chanfeed): [::http::error $t]"
	}
	"ok" {
		switch -glob [::http::ncode $t] {
		3* {
			upvar #0 $t state
			array set meta $state(meta)
			fetch $meta(Location) $chanfeed $args
		}
		200 {
			process [::http::data $t] $chanfeed
		}
		default {
			putlog "$version: ERROR($chanfeed): [::http::code $t]"
		}}
	}
	default {
		putlog "$version: ERROR($chanfeed): got EOF from socket"
	}}
	::http::cleanup $t
}

proc process {data chanfeed} {
	variable news; variable hash
	variable maxnew; variable source
	set idx 1; set count 0
	scan $chanfeed {%[^:]:%s} feed chan
	set news($chanfeed) {}; set source($chanfeed) ""
	if {[regexp {(?i)<title>(.*?)</title>} $data -> foo]} {
		append source($chanfeed) $foo
	}
	if {[regexp {(?i)<description>(.*?)</description>} $data -> foo]} {
		append source($chanfeed) " | $foo"
	}
	set infoline $source($chanfeed)
	regsub -all {(?i)<items.*?>.*?</items>} $data {} data
	foreach {foo item} [regexp -all -inline {(?i)<item.*?>(.*?)</item>} $data] {
		regexp {(?i)<title.*?>(.*?)</title>}  $item -> title
		regexp {(?i)<link.*?>(.*?)</link}     $item -> link
		regexp {(?i)<desc.*?>(.*?)</desc.*?>} $item -> descr
		if {![info exists title]} {set title "(none)"}
		if {![info exists link]}  {set link  "(none)"}
		if {![info exists descr]} {set descr "(none)"}
		strip title link descr
		if {[info exists hash($chanfeed)]} {
		if {[lsearch -exact $hash($chanfeed) [md5 $title]] == -1 && [botonchan $chan]} {
			if {![info exists header]} {
				if {$infoline == ""} {set header $feed} {set header $infoline} 
				puthelp "privmsg $chan :\002Breaking news\002 from $header!"
			}
			if {$count < $maxnew} {
				puthelp "privmsg $chan :($idx) $title"
				incr count
			} {
				lappend indices $idx
			}
		}}
		lappend news($chanfeed) [list $title $link $descr]
		lappend hashes [md5 $title]
		incr idx
	}
	if {[info exists indices] && [botonchan $chan]} {
		set count [llength $indices]
		set indices "(indices: [join $indices {, }])"
		puthelp "privmsg $chan :...and $count more $indices" 
	}
	set hash($chanfeed) $hashes
}

proc strip {args} {
	variable html
	foreach a $args {
		upvar $a x
		set amp {&amp; &}
		set x [string map $amp $x]
		set x [string map $html $x]
		while {[regexp -indices {(&#[0-9]{1,3};)} $x -> idxs]} {
			set b [lindex $idxs 0]; set e [lindex $idxs 1]
			set num [string range $x [expr {$b+2}] [expr {$e-1}]]
			if {$num < 256} {
				set x [string replace $x $b $e [format %c $num]]
			}
		}
		regexp {(?i)<!\[CDATA\[(.*?)\]\]>}   $x ->    x
		regsub -all {(?i)</t[dr]><t[dr].*?>} $x { | } x
		regsub -all {(?i)(<p>|<br>|\n)}      $x { }   x
		regsub -all {<[^<]+?>}               $x {}    x
	}
}

proc rss {hand idx text} {
	variable feeds
	if {$text == ""} {
		putdcc $idx "Usage: .$::lastbind <add|del|list> \[name:#chan \[feed\]\]"
		return
	}
	set text [split $text]
	switch [lindex $text 0] {
		"list" {
			if {[info exists feeds]} {
			foreach {chanfeed settings} [array get feeds] {
				putdcc $idx "$chanfeed -> [join $settings]" 
			}}
		}
		"add" {
			if {[llength $text] < 4} {
				putdcc $idx "not enough add arguments"
				return
			}
			set chanfeed [lindex $text 1]
			if {[info exists feeds]} {
			set names [string tolower [array names feeds]]
			if {[lsearch -exact $names [string tolower $chanfeed]] != -1} {
				putdcc $idx "$chanfeed already exists"
				return
			}}
			set feeds($chanfeed) [lrange $text 2 end]
		}
		"del" {
			set chanfeed [lindex $text 1]
			if {[info exists feeds]} {
			set names [string tolower [array names feeds]]
			if {[lsearch -exact $names [string tolower $chanfeed]] == -1} {
				putdcc $idx "$chanfeed does not exist"
				return
			} {
				unset feeds($chanfeed) 
			}}
		}
		default {
			putdcc $idx "invalid sub-command"
			return
		}

	}
	return 1 
}

proc news {nick uhost hand chan text} {
	variable source
	variable news; variable feeds
	variable pcount; variable pubflud
	if {[info exists pcount]} {
		set n [lindex $pcount 1]; incr n
		set ts [lindex $pcount 0]
		set pcount [list $ts $n]
		scan $pubflud {%[^:]:%s} maxr maxt
		if {$n >= $maxr} {
			if {[unixtime] - $ts <= $maxt} {return}
			set n 1; set ts [unixtime]
		}
	} {
		set n 1; set ts [unixtime]
	}
	set pcount [list $ts $n]
	set num [lindex [split $text] 1]
	set feed [lindex [split $text] 0]
	if {$text == ""} {
		foreach {key value} [array get feeds] {
			scan $key {%[^:]:%s} name channel
			if {[string eq -noc $chan $channel]} {
				lappend names $name
			}
		}
		if {[info exists names]} {
			set names [join $names {, }]
			puthelp "notice $nick :feed(s) for $chan: $names"
			puthelp "notice $nick :type $::lastbind <feed> \[index#\]"
		} {
			puthelp "notice $nick :no feed(s) for $chan"
		}
		return 1
	}
	if {![info exists news($feed:$chan)]} {
		puthelp "notice $nick :no news from $feed on $chan"
		return 1
	}
	if {$num == ""} {
		set idx 1
		if {$source($feed:$chan) != ""} {
			set title $source($feed:$chan)
		} {
			set title [lindex $feeds($feed:$chan) 1]
		}
		puthelp "notice $nick :News source: \002$title\002"
		foreach item $news($feed:$chan) {
			puthelp "notice $nick :($idx) [lindex $item 0]"
			incr idx
		}
		return 1
	} elseif {![string is integer $num]} {
		puthelp "notice $nick :news index must be number"
		return 1
	}
	if {$num < 1 || $num > [llength $news($feed:$chan)]} {
		puthelp "notice $nick :no such news index, try $::lastbind $feed"
		return 1
	} {
		set idx [expr {$num-1}]
		puthelp "notice $nick :......title($num): [lindex [lindex $news($feed:$chan) $idx] 0]"
		puthelp "notice $nick :description($num): [lindex [lindex $news($feed:$chan) $idx] 2]"
		puthelp "notice $nick :.......link($num): [lindex [lindex $news($feed:$chan) $idx] 1]"
		return 1
	}
}

# this proc courtesy of RS,
# from http://wiki.tcl.tk/775 
proc b64en str {
	binary scan $str B* bits
	switch [expr {[string length $bits]%6}] {
		0 {set tail ""}
		2 {append bits 0000; set tail ==}
		4 {append bits 00; set tail =}
	}
	return [string map {
		000000 A 000001 B 000010 C 000011 D 000100 E 000101 F
		000110 G 000111 H 001000 I 001001 J 001010 K 001011 L
		001100 M 001101 N 001110 O 001111 P 010000 Q 010001 R
		010010 S 010011 T 010100 U 010101 V 010110 W 010111 X
		011000 Y 011001 Z 011010 a 011011 b 011100 c 011101 d
		011110 e 011111 f 100000 g 100001 h 100010 i 100011 j
		100100 k 100101 l 100110 m 100111 n 101000 o 101001 p
		101010 q 101011 r 101100 s 101101 t 101110 u 101111 v
		110000 w 110001 x 110010 y 110011 z 110100 0 110101 1
		110110 2 110111 3 111000 4 111001 5 111010 6 111011 7
		111100 8 111101 9 111110 + 111111 /
	} $bits]$tail
}

variable html {
	&quot;     \x22  &apos;     \x27  &amp;      \x26  &lt;       \x3C
	&gt;       \x3E  &nbsp;     \x20  &iexcl;    \xA1  &curren;   \xA4
	&cent;     \xA2  &pound;    \xA3  &yen;      \xA5  &brvbar;   \xA6
	&sect;     \xA7  &uml;      \xA8  &copy;     \xA9  &ordf;     \xAA
	&laquo;    \xAB  &not;      \xAC  &shy;      \xAD  &reg;      \xAE
	&macr;     \xAF  &deg;      \xB0  &plusmn;   \xB1  &sup2;     \xB2
	&sup3;     \xB3  &acute;    \xB4  &micro;    \xB5  &para;     \xB6
	&middot;   \xB7  &cedil;    \xB8  &sup1;     \xB9  &ordm;     \xBA
	&raquo;    \xBB  &frac14;   \xBC  &frac12;   \xBD  &frac34;   \xBE
	&iquest;   \xBF  &times;    \xD7  &divide;   \xF7  &Agrave;   \xC0
	&Aacute;   \xC1  &Acirc;    \xC2  &Atilde;   \xC3  &Auml;     \xC4
	&Aring;    \xC5  &AElig;    \xC6  &Ccedil;   \xC7  &Egrave;   \xC8
	&Eacute;   \xC9  &Ecirc;    \xCA  &Euml;     \xCB  &Igrave;   \xCC
	&Iacute;   \xCD  &Icirc;    \xCE  &Iuml;     \xCF  &ETH;      \xD0
	&Ntilde;   \xD1  &Ograve;   \xD2  &Oacute;   \xD3  &Ocirc;    \xD4
	&Otilde;   \xD5  &Ouml;     \xD6  &Oslash;   \xD8  &Ugrave;   \xD9
	&Uacute;   \xDA  &Ucirc;    \xDB  &Uuml;     \xDC  &Yacute;   \xDD
	&THORN;    \xDE  &szlig;    \xDF  &agrave;   \xE0  &aacute;   \xE1
	&acirc;    \xE2  &atilde;   \xE3  &auml;     \xE4  &aring;    \xE5
	&aelig;    \xE6  &ccedil;   \xE7  &egrave;   \xE8  &eacute;   \xE9
	&ecirc;    \xEA  &euml;     \xEB  &igrave;   \xEC  &iacute;   \xED
	&icirc;    \xEE  &iuml;     \xEF  &eth;      \xF0  &ntilde;   \xF1
	&ograve;   \xF2  &oacute;   \xF3  &ocirc;    \xF4  &otilde;   \xF5
	&ouml;     \xF6  &oslash;   \xF8  &ugrave;   \xF9  &uacute;   \xFA
	&ucirc;    \xFB  &uuml;     \xFC  &yacute;   \xFD  &thorn;    \xFE
	&yuml;     \xFF
}

}
