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
set feeds(google:#dukelovett) {1 http://news.google.com/news?ned=us&topic=h&output=rss}
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

variable version "drss 0.1.1"

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
bind pub  - !rss [namespace current]::news
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
	set data [webbydescdecode $data]
	if {[regexp {<title>(.*?)</title>} $data -> foo]} {
		append source($chanfeed) $foo
	}
	if {[regexp {<description>(.*?)</description>} $data -> foo]} {
		append source($chanfeed) " | $foo"
	}
	set infoline $source($chanfeed)
	regsub -all {(?i)<items.*?>.*?</items>} $data {} data
	foreach {foo item} [regexp -all -inline {(?i)<item.*?>(.*?)</item>} $data] {
		regexp {(?i)<title.*?>(.*?)</title>}  $item titsub1 title 
		regexp {(?i)<link>(.*?)</link>}     $item linsub1 link
		regexp {(?i)<description>(.*?)</description} $item dessub1 descr
		set descr [unhtml $descr]; set title [unhtml $title]; set link [unhtml $link]
		if {![info exists title]} {set title "(none)"}
		if {![info exists link]}  {set link  "(none)"}
		if {![info exists descr]} {set descr "(none)"}
		if {[info exists hash($chanfeed)]} {
		if {[lsearch -exact $hash($chanfeed) [md5 $title]] == -1 && [botonchan $chan]} {
			if {![info exists header]} {
				if {$infoline == ""} {set header $feed} {set header $infoline}
				set header [unhtml $header]
				puthelp "notice $chan :\002Breaking news\002: $header!"
			}
			if {$count < $maxnew} {
				puthelp "notice $chan :($idx) $title ~ $link"
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
		puthelp "notice $chan :...and $count more $indices" 
	}
	set hash($chanfeed) $hashes
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
			puthelp "notice $chan :feed(s) for $chan: $names"
			puthelp "notice $chan :type $::lastbind <feed> \[index#\]"
		} {
			puthelp "notice $chan :no feed(s) for $chan"
		}
		return 1
	}
	if {![info exists news($feed:$chan)]} {
		puthelp "notice $chan :no news from $feed on $chan"
		return 1
	}
	if {$num == ""} {
		set idx 1
		if {$source($feed:$chan) != ""} {
			set title $source($feed:$chan)
		} {
			set title [lindex $feeds($feed:$chan) 1]
		}
		set title [unhtml $title]
		puthelp "notice $chan :News source: \002$title\002"
		foreach item $news($feed:$chan) {
			puthelp "notice $chan:($idx) [lindex $item 0]"
			incr idx
		}
		return 1
	} elseif {![string is integer $num]} {
		puthelp "notice $chan :news index must be number"
		return 1
	}
	if {$num < 1 || $num > [llength $news($feed:$chan)]} {
		puthelp "notice $chan:no such news index, try $::lastbind $feed"
		return 1
	} {
		set idx [expr {$num-1}]
		puthelp "notice $chan :......title($num): [lindex [lindex $news($feed:$chan) $idx] 0]"
		puthelp "notice $chan :description($num): [lindex [lindex $news($feed:$chan) $idx] 2]"
		puthelp "notice $chan :.......link($num): [lindex [lindex $news($feed:$chan) $idx] 1]"
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

proc unhtml {text} {
  regsub -all "(?:<b>|</b>|<b />|<em>|</em>|<strong>|</strong>)" $text "\002" text
  regsub -all "(?:<u>|</u>|<u />)" $text "\037" text
  regsub -all "(?:<br>|<br/>|<br />)" $text ". " text
  regsub -all "<script.*?>.*?</script>" $text "" text
  regsub -all "<style.*?>.*?</style>" $text "" text
  regsub -all -- {<.*?>} $text " " text
  while {[string match "*  *" $text]} { regsub -all "  " $text " " text }
  return [string trim $text]
}
proc webbydescdecode {text} {
  # code below is neccessary to prevent numerous html markups
  # from appearing in the output (ie, &quot;, &#5671;, etc)
  # stolen (borrowed is a better term) from perplexa's urban
  # dictionary script..
  if {![string match *&* $text]} {return $text}
  set escapes {
               &nbsp; \xa0 &iexcl; \xa1 &cent; \xa2 &pound; \xa3 &curren; \xa4
               &yen; \xa5 &brvbar; \xa6 &sect; \xa7 &uml; \xa8 &copy; \xa9
               &ordf; \xaa &laquo; \xab &not; \xac &shy; \xad &reg; \xae
               &macr; \xaf &deg; \xb0 &plusmn; \xb1 &sup2; \xb2 &sup3; \xb3
               &acute; \xb4 &micro; \xb5 &para; \xb6 &middot; \xb7 &cedil; \xb8
               &sup1; \xb9 &ordm; \xba &raquo; \xbb &frac14; \xbc &frac12; \xbd
               &frac34; \xbe &iquest; \xbf &Agrave; \xc0 &Aacute; \xc1 &Acirc; \xc2
               &Atilde; \xc3 &Auml; \xc4 &Aring; \xc5 &AElig; \xc6 &Ccedil; \xc7
               &Egrave; \xc8 &Eacute; \xc9 &Ecirc; \xca &Euml; \xcb &Igrave; \xcc
               &Iacute; \xcd &Icirc; \xce &Iuml; \xcf &ETH; \xd0 &Ntilde; \xd1
               &Ograve; \xd2 &Oacute; \xd3 &Ocirc; \xd4 &Otilde; \xd5 &Ouml; \xd6
               &times; \xd7 &Oslash; \xd8 &Ugrave; \xd9 &Uacute; \xda &Ucirc; \xdb
               &Uuml; \xdc &Yacute; \xdd &THORN; \xde &szlig; \xdf &agrave; \xe0
               &aacute; \xe1 &acirc; \xe2 &atilde; \xe3 &auml; \xe4 &aring; \xe5
               &aelig; \xe6 &ccedil; \xe7 &egrave; \xe8 &eacute; \xe9 &ecirc; \xea
               &euml; \xeb &igrave; \xec &iacute; \xed &icirc; \xee &iuml; \xef
               &eth; \xf0 &ntilde; \xf1 &ograve; \xf2 &oacute; \xf3 &ocirc; \xf4
               &otilde; \xf5 &ouml; \xf6 &divide; \xf7 &oslash; \xf8 &ugrave; \xf9
               &uacute; \xfa &ucirc; \xfb &uuml; \xfc &yacute; \xfd &thorn; \xfe
               &yuml; \xff &fnof; \u192 &Alpha; \u391 &Beta; \u392 &Gamma; \u393 &Delta; \u394
               &Epsilon; \u395 &Zeta; \u396 &Eta; \u397 &Theta; \u398 &Iota; \u399
               &Kappa; \u39A &Lambda; \u39B &Mu; \u39C &Nu; \u39D &Xi; \u39E
               &Omicron; \u39F &Pi; \u3A0 &Rho; \u3A1 &Sigma; \u3A3 &Tau; \u3A4
               &Upsilon; \u3A5 &Phi; \u3A6 &Chi; \u3A7 &Psi; \u3A8 &Omega; \u3A9
               &alpha; \u3B1 &beta; \u3B2 &gamma; \u3B3 &delta; \u3B4 &epsilon; \u3B5
               &zeta; \u3B6 &eta; \u3B7 &theta; \u3B8 &iota; \u3B9 &kappa; \u3BA
               &lambda; \u3BB &mu; \u3BC &nu; \u3BD &xi; \u3BE &omicron; \u3BF
               &pi; \u3C0 &rho; \u3C1 &sigmaf; \u3C2 &sigma; \u3C3 &tau; \u3C4
               &upsilon; \u3C5 &phi; \u3C6 &chi; \u3C7 &psi; \u3C8 &omega; \u3C9
               &thetasym; \u3D1 &upsih; \u3D2 &piv; \u3D6 &bull; \u2022
               &hellip; \u2026 &prime; \u2032 &Prime; \u2033 &oline; \u203E
               &frasl; \u2044 &weierp; \u2118 &image; \u2111 &real; \u211C
               &trade; \u2122 &alefsym; \u2135 &larr; \u2190 &uarr; \u2191
               &rarr; \u2192 &darr; \u2193 &harr; \u2194 &crarr; \u21B5
               &lArr; \u21D0 &uArr; \u21D1 &rArr; \u21D2 &dArr; \u21D3 &hArr; \u21D4
               &forall; \u2200 &part; \u2202 &exist; \u2203 &empty; \u2205
               &nabla; \u2207 &isin; \u2208 &notin; \u2209 &ni; \u220B &prod; \u220F
               &sum; \u2211 &minus; \u2212 &lowast; \u2217 &radic; \u221A
               &prop; \u221D &infin; \u221E &ang; \u2220 &and; \u2227 &or; \u2228
               &cap; \u2229 &cup; \u222A &int; \u222B &there4; \u2234 &sim; \u223C
               &cong; \u2245 &asymp; \u2248 &ne; \u2260 &equiv; \u2261 &le; \u2264
               &ge; \u2265 &sub; \u2282 &sup; \u2283 &nsub; \u2284 &sube; \u2286
               &supe; \u2287 &oplus; \u2295 &otimes; \u2297 &perp; \u22A5
               &sdot; \u22C5 &lceil; \u2308 &rceil; \u2309 &lfloor; \u230A
               &rfloor; \u230B &lang; \u2329 &rang; \u232A &loz; \u25CA
               &spades; \u2660 &clubs; \u2663 &hearts; \u2665 &diams; \u2666
               &quot; \x22 &amp; \x26 &lt; \x3C &gt; \x3E O&Elig; \u152 &oelig; \u153
               &Scaron; \u160 &scaron; \u161 &Yuml; \u178 &circ; \u2C6
               &tilde; \u2DC &ensp; \u2002 &emsp; \u2003 &thinsp; \u2009
               &zwnj; \u200C &zwj; \u200D &lrm; \u200E &rlm; \u200F &ndash; \u2013
               &mdash; \u2014 &lsquo; \u2018 &rsquo; \u2019 &sbquo; \u201A
               &ldquo; \u201C &rdquo; \u201D &bdquo; \u201E &dagger; \u2020
               &Dagger; \u2021 &permil; \u2030 &lsaquo; \u2039 &rsaquo; \u203A
               &euro; \u20AC &apos; \u0027 &lrm; "" &rlm; "" &#8236; "" &#8237; ""
               &#8238; "" &#8212; \u2014
  };
  set text [string map [list "\]" "\\\]" "\[" "\\\[" "\$" "\\\$" "\\" "\\\\"] [string map $escapes $text]]
  regsub -all -- {&#([[:digit:]]{1,5});} $text {[format %c [string trimleft "\1" "0"]]} text
  regsub -all -- {&#x([[:xdigit:]]{1,4});} $text {[format %c [scan "\1" %x]]} text
  regsub -all -- {\\x([[:xdigit:]]{1,2})} $text {[format %c [scan "\1" %x]]} text
  set text [subst "$text"]
  return $text
}
}
