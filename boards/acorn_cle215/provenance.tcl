# provenance.tcl - what a Vivado build of this repository is made from (sourced by build.tcl, build_batch.tcl and
# build_split.tcl). A build reads the commit checked out when it starts, never the files as they are later on: on
# 2026-10-13 a build read the decoder's sources minutes after it started (build_split.tcl synthesizes the DDR3
# controller first) while they were being edited, and its bitstream matched no commit.
#
#   prov_init <build script>     after sourcing this file: the repository (git) and the scripts that run the build
#   prov_snapshot <out> <files> [-external]
#       copies each file into <out>/src/<its path in the repository> at once and checks the copy against the commit
#       checked out: its git blob must be the commit's (git hash-object --no-filters = git rev-parse <commit>:<path>).
#       The build reads the copies (prov_path), so nothing changed in the working tree afterwards can reach it.
#       -external: files outside the repository (third-party sources): copied, their sha256 recorded, not checked.
#   prov_path <file>, prov_paths <files>   the copies taken by prov_snapshot
#   prov_list <files.f>          the file names a files.f lists (comments and blank lines skipped)
#   prov_write <out> <what> [name]  writes <out>/provenance.txt (or <out>/<name>): the commit, the branch, Vivado's
#       version, <what> (top, part, parameters, options), the blob and sha256 of every source and of the build scripts
#       (which must be the commit's too). Stops the build if a file differs from the commit or is not in it - unless
#       BUILD_UNCOMMITTED=1: then the build goes on, provenance.txt says UNCOMMITTED and lists the files, and the
#       bitstream stays unstamped.
#   prov_id <out> [name]         "commit <hash> <state>" from provenance.txt, for a result file's first line
#   prov_stage <out> <checkpoint>  a later stage in a process of its own (place, route): the scripts running must
#       still be the commit's, and the checkpoint must be newer than provenance.txt (made from this snapshot)
#   prov_stamp <out>             before write_bitstream: USERID = the commit's first 8 hex digits, so every copy of
#       the bitstream names its commit (the .bit header reads UserID=<8 hex digits>; the default UserID=0XFFFFFFFF
#       = unstamped)
#   prov_bit <out> <bit>         after write_bitstream: checks the header's UserID, records the bitstream's sha256
namespace eval prov {
  variable here [file dirname [file normalize [info script]]]
  variable root ""            ;# the repository's top directory ("" = not a git checkout)
  variable commit ""          ;# the commit checked out, resolved once
  variable scripts {}         ;# the build script and this file
  variable rec {}             ;# one line per source: blob sha256 path
  variable bad {}             ;# files that are not the commit's
  variable map; array set map {}
}

proc prov::git {args} { return [exec git -C $prov::root {*}$args] }

proc prov::sha256 {f} {
  if {[catch {exec sha256sum $f} r]} { return "-" }
  return [lindex $r 0]
}

# a file's path inside the repository, "" if outside it (or no repository)
proc prov::rel {f} {
  set f [file normalize $f]
  if {$prov::root eq "" || [string first "$prov::root/" $f] != 0} { return "" }
  return [string range $f [string length "$prov::root/"] end]
}

# "" if file f holds exactly the blob of <commit>:<rel>, else what is wrong
proc prov::check {f rel commit} {
  if {$commit eq "" || [catch {prov::git rev-parse --verify --quiet "$commit:$rel"} want]} { return "not in the commit" }
  if {[catch {prov::git hash-object --no-filters [file normalize $f]} got]} { return "unreadable: $got" }
  if {$got ne $want} { return "differs from the commit" }
  return ""
}

# one record line for file f (named rel, or orig outside the repository): the blob (if the commit's), sha256, name;
# a file that is not the commit's goes into prov::bad
proc prov::record {f rel orig what} {
  # (if/else, not expr's ?: - expr would turn a hash or a version that looks like a number into one)
  if {$rel eq ""} {
    set name $orig; set e "outside the repository, or not a git checkout"
  } else {
    set name $rel; set e [prov::check $f $rel $prov::commit]
  }
  set blob "-"
  if {$e ne ""} { lappend prov::bad "$name ($what$e)" } else { set blob [prov::git rev-parse "$prov::commit:$rel"] }
  return "$blob [prov::sha256 $f] $name"
}

proc prov_init {script} {
  set prov::scripts [list [file normalize $script] [file normalize $prov::here/provenance.tcl]]
  if {[catch {exec git -C $prov::here rev-parse --show-toplevel} r]} { return }
  set prov::root [file normalize $r]
  if {[catch {prov::git rev-parse --verify HEAD} c]} { set prov::root ""; return }
  set prov::commit $c
}

proc prov_snapshot {out files {mode ""}} {
  set out [file normalize $out]
  foreach f $files {
    set f [file normalize $f]
    set rel [prov::rel $f]
    if {$rel ne "" && $mode ne "-external"} {
      set dst [file join $out src $rel]
    } else {
      set dst [file join $out src external [string trimleft $f /]]
    }
    file mkdir [file dirname $dst]
    file copy -force $f $dst
    set prov::map($f) $dst
    if {$mode eq "-external"} {
      lappend prov::rec "external [prov::sha256 $dst] $f"
    } else {
      lappend prov::rec [prov::record $dst $rel $f ""]
    }
  }
  return [prov_paths $files]
}

proc prov_path {f} {
  set f [file normalize $f]
  if {![info exists prov::map($f)]} { error "provenance: $f was not taken into the snapshot (prov_snapshot)" }
  return $prov::map($f)
}

proc prov_paths {files} {
  set r {}
  foreach f $files { lappend r [prov_path $f] }
  return $r
}

proc prov_list {ff} {
  set fh [open $ff]; set txt [read $fh]; close $fh
  set r {}
  foreach line [split $txt "\n"] {
    set f [string trim $line]
    if {$f ne "" && [string index $f 0] ne "/"} { lappend r $f }
  }
  return $r
}

proc prov_write {out what {name provenance.txt}} {
  set srec $prov::rec
  set prov::rec {}
  foreach s $prov::scripts { lappend prov::rec [prov::record $s [prov::rel $s] $s "build script: "] }
  set allow [expr {[info exists ::env(BUILD_UNCOMMITTED)] && $::env(BUILD_UNCOMMITTED) eq "1"}]
  if {[llength $prov::bad] && !$allow} {
    set how "Build from a clean checkout of one commit (git worktree add --detach <dir> <commit>),\
             or set BUILD_UNCOMMITTED=1 for an unstamped build"
    if {$prov::root eq ""} { error "provenance: $prov::here is not in a git checkout, so no commit to build. $how" }
    error "provenance: this build would not read the commit checked out ([string range $prov::commit 0 7]):\
           [join $prov::bad {; }]. $how"
  }
  set other 0
  if {$prov::root ne "" && ![catch {prov::git status --porcelain --untracked-files=no} st] && [string trim $st] ne ""} {
    set other [llength [split [string trim $st] "\n"]]
  }
  set branch "-"
  if {$prov::root ne "" && [catch {prov::git symbolic-ref --short -q HEAD} branch]} { set branch "(detached)" }
  set commit $prov::commit; if {$commit eq ""} { set commit "-" }
  set root $prov::root; if {$root eq ""} { set root "-" }
  if {[catch {version -short} vivado]} { set vivado "-" }
  set fh [open $out/$name w]
  puts $fh "commit     $commit"
  if {[llength $prov::bad]} {
    puts $fh "state      UNCOMMITTED (BUILD_UNCOMMITTED=1: [llength $prov::bad] file(s) not the commit's; the bitstream stays unstamped)"
  } else {
    puts $fh "state      committed (every file this build reads is the commit's)"
  }
  puts $fh "branch     $branch"
  puts $fh "checkout   $root ($other modified file(s) in the checkout)"
  puts $fh "snapshot   [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}], into $out/src"
  puts $fh "vivado     $vivado"
  puts $fh "build      $what"
  set ext [llength [lsearch -all $srec "external *"]]
  if {$ext} { puts $fh "external   $ext file(s) from outside the repository (third-party): sha256 recorded, not checked" }
  foreach b $prov::bad { puts $fh "NOT THE COMMIT'S: $b" }
  puts $fh "scripts (git blob, sha256, path):"
  foreach r $prov::rec { puts $fh "  $r" }
  puts $fh "sources (git blob, sha256, path):"
  foreach r $srec { puts $fh "  $r" }
  close $fh
  puts "PROVENANCE [string range $prov::commit 0 7] [expr {[llength $prov::bad] ? "UNCOMMITTED" : "committed"}]:\
        [llength $srec] sources copied into $out/src"
}

# the commit and state written by prov_write (for the stages that run in processes of their own)
proc prov::load {out {name provenance.txt}} {
  if {![file exists $out/$name]} { error "provenance: no $out/$name (run the synthesis stage first)" }
  set fh [open $out/$name]; set txt [read $fh]; close $fh
  if {![regexp -line {^commit +(\S+)} $txt -> c] || ![regexp -line {^state +(\S+)} $txt -> s]} {
    error "provenance: $out/$name unreadable"
  }
  return [list $c $s]
}

proc prov_id {out {name provenance.txt}} {
  lassign [prov::load $out $name] c s
  return "commit $c $s"
}

proc prov_stage {out checkpoint} {
  lassign [prov::load $out] c s
  if {$s eq "committed"} {
    foreach f $prov::scripts {
      set rel [prov::rel $f]
      if {$rel eq ""} { set e "outside the repository" } else { set e [prov::check $f $rel $c] }
      if {$e ne ""} { error "provenance: the script running ($f) is not the snapshot's commit [string range $c 0 7]: $e" }
    }
  }
  if {![file exists $checkpoint] || [file mtime $checkpoint] < [file mtime $out/provenance.txt]} {
    error "provenance: $checkpoint is missing or older than $out/provenance.txt (not made from this snapshot)"
  }
  puts "PROVENANCE [string range $c 0 7] $s: [file tail $checkpoint] from this snapshot"
}

proc prov_stamp {out} {
  lassign [prov::load $out] c s
  if {$s ne "committed"} { puts "PROVENANCE the bitstream stays unstamped (UserID FFFFFFFF): uncommitted sources"; return }
  set id [string toupper [string range $c 0 7]]
  set_property BITSTREAM.CONFIG.USERID "0x$id" [current_design]
  puts "PROVENANCE USERID 0x$id (commit $c)"
}

proc prov_bit {out bit} {
  lassign [prov::load $out] c s
  set fh [open $bit rb]; set h [read $fh 512]; close $fh
  # Vivado 2026.1 writes the default as UserID=0XFFFFFFFF, a value set as UserID=2BDD7396 (leading zeros, if it drops
  # them, restored)
  if {![regexp {UserID=(?:0X)?([0-9A-F]{1,8})} $h -> uid]} { error "provenance: no UserID in the header of $bit" }
  set uid [string range "00000000$uid" end-7 end]
  set want FFFFFFFF; if {$s eq "committed"} { set want [string toupper [string range $c 0 7]] }
  if {$uid ne $want} { error "provenance: $bit has UserID $uid, expected $want" }
  set fh [open $out/provenance.txt a]
  puts $fh "bitstream  [file tail $bit] UserID $uid sha256 [prov::sha256 $bit],\
            written [clock format [file mtime $bit] -format {%Y-%m-%d %H:%M:%S}]"
  close $fh
  puts "PROVENANCE bitstream [file tail $bit] UserID $uid"
}
