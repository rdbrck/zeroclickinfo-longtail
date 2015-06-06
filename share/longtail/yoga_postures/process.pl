#!/usr/local/bin/perl
   
use WWW::Mechanize; 
use File::Path 'make_path';
use File::Slurp qw'read_file write_file';
use YAML::XS qw(Load DumpFile);
use HTML::TableExtract;
use Text::Autoformat;
use Data::Printer;

use strict;

my $data_dir = 'download';

# sources
my $ayi_url = 'http://www.ashtangayoga.info/practice/';
my $ayi_dir = 'ashtanga.info';

my $yc_url = 'https://yoga.com/api/content/feed/?format=json&type=pose&offset=0&limit=500';
my $yc_file = 'yoga.com.yaml';

my $yp_url = 'http://www.theyogaposes.com/';

# Our output file
my $output_file = 'output.xml';

# Common variation alternatives
my %variations = (A => 'I', B => 'II', C => 'III', D => 'IV');

# A single http client
my $m = WWW::Mechanize->new(agent => 'Mozilla/5.0 (X11; FreeBSD amd64; rv:30.0) Gecko/20100101 Firefox/30.0');

my (%skip, $verbose, @docs);

MAIN:{
    parse_argv();
    process_ayi() unless $skip{ayi};
    process_yc() unless $skip{yc};
    process_yp() unless $skip{yp};
    create_xml();
}


sub process_ayi {

    my $archive = "$data_dir/$ayi_dir";
    make_path($archive);

    my $r = $m->get($ayi_url);
    die "Failed to get AYI practices: " . $r->status_line unless $r->is_success;

    my $practice_links = $m->find_all_links(url_regex => qr{practice/[^/]+/$});

    my %seen;

    for my $pl (@$practice_links){
        my $practice = $pl->text;

        my $url = $pl->url;
        next if $seen{$url}++ || ($url =~ /mp3|pdf/i);
        $url .= 'opt/info/' if $url =~ /surya-namaskara/;

        my $r = $m->get($url);
        unless($r->is_success){
            die "Failed to retrieve $url: " . $r->status_line;
        }
        unless($url =~ m{/([^/]+)/$}){
            die "Failed to extract practice from $url";
        }
        my $p = $1;
        if($p =~ /^(surya-namaskara-(?:a|b))/o){
            parse_ayi($p, $url, $r->decoded_content);
        }
        my $links = $m->find_all_links(url_regex => qr{practice/$p/item/[^/]+/$}, text_regex => qr{^[^\[]+$});

        my $order = 0;
        for my $l (@$links){
            my $url = $l->url;
            next if $url =~ m{-\d+/$}o; # unnamed transition postures
            unless($url =~ m{/([^/]+)/$}o){
                die "Failed to extract asana from $url";
            }
            ++$order;
            my $file = "$archive/${order}_$1.html";

            unless(-e $file){
                warn "\tGetting ", $l->url, ' (text: ', $l->text, ")\n";
                my $res = $m->get($l);
                if($res->is_success){
                    warn "\tSaving $file\n";
                    write_file($file, {binmode => ':utf8'}, "<!-- source: $url -->\n", $res->decoded_content);
                }
                else{
                    die "Failed to retrieve $url: " . $res->status_line;
                }
            }

            if(my $htm = read_file( $file, binmode => ':utf8' )){
                parse_ayi($p, $url, $htm, $order);
            }
        }
    }
}

sub process_yc {
    my $r = $m->get($yc_url);
    unless($r->is_success){
        die "Failed to retrieve $yc_url: " . $r->status_line;
    }
    my $yc_data = Load($r->decoded_content);
    $m->get('https://yoga.com/pose/downward-facing-dog-pose');
    unless($r->is_success){
        die "Failed to retrieve $yc_url: " . $r->status_line;
    }
    my $l = $m->find_link(url_regex => qr{\.cloudfront\.net/static});
    my $iurl = $l->url;
    unless($iurl =~ m{^https?://([^/]+)}i){ # images appear to work both with and without SSL
        die "Failed to extract cloudfront image server from url $iurl";
    }
    my $imgsrv = $1;

    my (%out, $img_verified, $src_verified);
    for my $a (@{$yc_data->{payload}{objects}}){
        my $imgurl = 'http://' . $imgsrv . $a->{photo};
        unless($img_verified){ # basic check that our link composition still works
            my $r = $m->get($imgurl);
            unless($r->is_success){
                die "Failed to retrieve $imgurl: " . $r->status_line. '. Check that images are still begin served from cloudfront.net.';
            }
            ++$img_verified;
        }
        my $srcurl = join('/', 'https://yoga.com/pose', $a->{slug});
        unless($src_verified){ # basic check that our source link format still works
            my $r = $m->get($srcurl);
            unless($r->is_success){
                die "Failed to retrieve $srcurl: " . $r->status_line. '. Check that source format for photos is still https://yoga.com/post/[slug]/photo';
            }
            ++$src_verified;
        }
        if(exists $out{$a->{sanskrit_name}}){ # should be unique; if not, let's check it out
            warn $a->{sanskrit_name}, " already exists\n";
            next;
        }
        my $title = $a->{title};
        push @docs, {
            title => $a->{sanskrit_name},,
            l2sm => $title,
            pp => $title,
            img => $imgurl,
            meta => $srcurl
        };
    }
}

sub process_yp {
    my $r = $m->get($yp_url);
    unless($r->is_success){
        die "Failed to retrieve $yp_url: " . $r->status_line;
    }
    my $h = $r->decoded_content;
    my $te = HTML::TableExtract->new(keep_html => 1,
        headers => [
            'Sanskrit Name for Yoga Poses, Postures and Asanas',
            'English Name for Yoga Poses, Postures and Asanas',
            'Visual'
    ])->parse($h);

    for my $r ($te->rows){
        unless($r->[0] =~ m{href="(http[^"]+)">([^<]+)<}){
            die "Failed to extract source/name from $r->[0]";
        }
        my ($src, $title) = ($1, $2);

        unless($r->[1] =~ m{>[^<]+<}){
            die "Failed to extract translation from $r->[1]";
        }
        my $trans = $1;

        unless($r->[2] =~ m{src="(http[^"]+)"}){
            die "Failed to extract image link from $r->[2]";
        }
        my $img = $1;

        push @docs, {
            title => $title,
            l2sm => $trans,
            pp => $trans,
            img => $img,
            meta => $src
        };
    }
}

# command-line options
sub parse_argv {
    my $usage = <<ENDOFUSAGE;

    *******************************************************************
        USAGE: fetch.pl [-data path/to/data] [-no_*] [-v]

        -data: (optional) path to the download directory
        -no_*: (optional) turn off download of a site:
          ayi: ashtanga.info 
           yc: yoga.com
           yp: theyogaposts.com 
        -v: (optional) Turn on some parse warnings

    *******************************************************************

ENDOFUSAGE

    for(my $i = 0;$i < @ARGV;$i++) {
        if($ARGV[$i] =~ /^-data$/o) { $data_dir = $ARGV[++$i] }
        elsif($ARGV[$i] =~ /^-v$/o) { $verbose = 1; }
        elsif($ARGV[$i] =~ /^-no_(\w+)$/o) { ++$skip{$1} }
    }
}

# Process ashtangayoga.info
sub parse_ayi {
    my ($practice, $src, $htm, $order) = @_;

    my ($asana, $sasana, $img, $trans);
    if($practice =~ /^surya-namaskara/o){
        if(($asana, $sasana, $trans, $img) =
            $htm =~ m{
            <h1>(?'asana'[^<]+)</h1>.+?
            class="uniHeader">([^<]+)</h3>.+?
            <h2>([^<]+)</h2>(?s:.+)
            <img\s+src="([^"]+)".+<em>\g{asana}
        }ox){
            if($asana =~ /(\s[AB])$/o){
                $trans .= $1;
            }
            else{
                die "Failed to extract variation from $asana";
            }
        }
        else{
            die "Failed to extract information from $src";
        }
    }
    elsif(($asana, $sasana, $img) =
        $htm =~ m{
        <h1>(?'asana'[^<]+)</h1>(?s:.+)
        class="uniHeader">([^<]+)<(?s:.+)
        <img\s+src="([^"]+)"\s+width="\d+"\s+height="\d+"\s+alt="\g{asana}"\s+>
    }ox){
        $asana =~ s/\bMukah\b/Mukha/o; # sic
        my @aps = split /\s+/, $asana;

        # all of these are to extract the translation
        if($asana =~ /^Baddha\s+Hasta\s+Shirshasana/o){
            $aps[0] = 'Mukta'; # wrong
        }
        elsif($asana =~ /^Dvi\s+Pada\s+Shirshasana/o){
            $aps[0] = 'Eka'; # wrong
        }
        elsif($asana eq 'Kaundinyasana A'){
            $aps[0] = 'Koundinyasana'; # sic
        }
        elsif($asana =~ /^Prasarita\s+Padottanasana/o){
            $aps[0] = 'Parasarita'; # sic
        }
        elsif($asana =~ /^Supta\s+Trivikramasana/o){
            $aps[1] = 'Trivikrimasana'; # sic
        }
        elsif($asana =~ /Urdhva\s+Dandasana/){
            @aps = ('Shirshasana'); # wrong
        }
        elsif($asana eq 'Vatayanasana'){
            $aps[0] = 'Vatayasana'; # sic
        }
        elsif($asana =~ /^Viranchyasana/o){
            $aps[0] = 'Viranchhyasana'; # sic
        }

        # Really don't like having to search the document twice but there
        # are inconsistencies in the spacing of the asana, whether it has
        # A/B/C/D for variants, etc.
        my $trans_re;
        if($aps[-1] =~ /^[A-D]$/o){
            my $var = pop @aps;
            $trans_re = join('\s+', @aps) . "(?:\\s+$var)?";
        }
        else{
            $trans_re = join('\s+', @aps);
        }
        unless($htm =~ m{<p>.+<b>$trans_re</b>.+\)\s+(?:=\s+)?(.+?)</p>}){
            warn "Failed to extract translation from $src: '<p>.+<b>$trans_re</b>.+\)\s+(?:=\s+)?(.+?)</p>'\n";
        }
        $trans = $1;
        $trans =~ s{<b>([^<]+)</b>\s*\([^,]+,\s*([^)]+)\)}{$1/$2};
    }
    else{
        warn "Failed to extract values from $src";
    }

    my $pcount = $order;

    for ($asana, $sasana, $trans, $practice){
        s/-/ /og;
        tr/ //s;
    }

    # the sanskrit doesn't have the variation usually
    if($asana =~ /\s([A-D])$/o){
        my $var = $1;
        $sasana .= " $var $variations{$var}" unless $sasana =~ /$var$/;
    }

    my $desc = $trans;
    # many will know these as Warrior, not Hero
    $trans =~ s{\bHero\b}{Hero/Warrior};
    unless($desc =~ /pose|posture/oi){
        $desc .= ' Posture';
    }
    # autoformat almost isn't worth using with its newlines
    $desc = autoformat($desc, {case => 'title'});
    $desc =~ s/\n+$//o;

    # We add "ashtanga vinyasa yoga" since it's a specific style
    push @docs, {
        title => $asana,
        l2sm => "ashtanga vinyasa $asana $trans $sasana $practice",
        pp => $desc,
        img => $img,
        meta => $src,
        pcount => $pcount
    };
}

sub create_xml {

    # Output the articles
    open my $output, '>:utf8', $output_file or die "Failed to open $output_file: $!";

    print $output qq|<?xml version="1.0" encoding="UTF-8"?>\n<add allowDups="true">|;

    for my $d (@docs){

        my ($title, $l2sm, $pp, $img, $meta, $pcount) = @$d{qw(title l2sm pp img meta pcount)};
        $l2sm =~ s{[-/]}{ }og;

        my $source = '<field name="source"><![CDATA[yoga_postures]]></field>';
        $source .= qq{\n<field name="p_count">$pcount</field>} if $pcount;

        print $output "\n", join("\n",
            qq{<doc>},
            qq{<field name="title"><![CDATA[$title]]></field>},
            qq{<field name="l2_sec_match2"><![CDATA[$l2sm]]></field>},
            qq{<field name="paragraph"><![CDATA[$pp]]></field>},
            $source,
            qq{<field name="meta"><![CDATA[{"url":"$meta","img":"$img"}]]></field>},
            qq{</doc>});
    }
    print $output "\n</add>";
}
