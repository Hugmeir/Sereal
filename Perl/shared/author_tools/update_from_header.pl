#!perl
use strict;
use warnings;
use Data::Dumper;
my (
    @meta,
    %name_to_value,             # just the names in the srl_protocol.h
    %name_to_value_expanded,    # names from srl_protocol, but with the LOW/HIGH data expanded
    %value_to_name_expanded,    # values from srl_protocol_expanded, mapping back, note value points at FIRST name
    %value_to_comment_expanded  # values from srl_protocol_expanded, with comments from file.
);
my $max_name_length= 0;

sub fill_ranges {
    my $pfx= shift;
    $pfx=~s/_LOW//;
    defined(my $ofs= $name_to_value_expanded{$pfx})
        or die "unknown $pfx";
    for my $value ( $name_to_value_expanded{$pfx . "_LOW"} .. $name_to_value_expanded{$pfx . "_HIGH"}) {
        my $n= $pfx=~/NEG/ ? abs($value - 32) : $value - $ofs;
        my $name= $pfx . "_" . $n;
        $name_to_value_expanded{ $name } ||= $value;
        $value_to_name_expanded{ $value } = $name;
        $value_to_comment_expanded{ $value } ||= '';

        $meta[$value]{name}= $name;
        $meta[$value]{value}= $value;
        $meta[$value]{type_name}= $pfx;
        $meta[$value]{type_value}= $ofs;
        #$meta[$value]{comment}= $value_to_comment_expanded{ $ofs }
        #    if exists $value_to_comment_expanded{ $ofs };

        $meta[$value]{masked_val}= $n;
        $meta[$value]{masked}= 1;

    }
    $value_to_comment_expanded{ $name_to_value_expanded{$pfx . "_HIGH"} } = $value_to_comment_expanded{ $ofs };
}
sub read_protocol {
    open my $fh,"<", "Perl/shared/srl_protocol.h"
        or die "Perl/shared/srl_protocol.h: $!";

    my @fill;
    while (<$fh>) {
        if(m!^#define\s+SRL_HDR_(\S+)\s+\(\(char\)(\d+)\)\s*(?:/\*\s*(.*?)\s*\*/)?\s*\z!i) {
            my ($name, $value, $comment)= ($1, $2, $3);
            $value= 0+$value;
            $name_to_value{$name}= $value;
            $name_to_value_expanded{$name}= $value;
            $value_to_name_expanded{$value} ||= $name;
            $value_to_comment_expanded{$value} ||= $comment;
            push @fill, $name if substr($name, -4) eq '_LOW';

            if ( $value < 128 ) {
                $meta[$value]{name}= $name;
                $meta[$value]{value}= $value;
                $meta[$value]{type_name}= $name;
                $meta[$value]{type_value}= $value;
                $meta[$value]{comment}= $comment if defined $comment;
            }
        }
    }
    close $fh;
    fill_ranges($_) for @fill;
    foreach my $pfx (keys %name_to_value_expanded) {
        $max_name_length= length($pfx) if $max_name_length < length($pfx);
    }
}

sub open_swap {
    my $file= shift;
    open my $fh,"<", $file
        or die "error opening $file for read:$!";
    rename $file,"$file.bak"
        or die "error renaming $file to $file.bak: $!";
    open my $out,">", $file
        or die "error opening $file for write (old version in $file.bak):$!";
    return ($fh,$out);
}

sub replace_block {
    my ($file,$blob)= @_;
    my ($in,$out)= open_swap($file);
    while (<$in>) {
        print $out $_;
        last if /^=for autoupdater start/ || /^# start autoupdated section/;
    }
    $blob=~s/\s+$//mg;
    print $out "\n$blob\n\n";
    while (<$in>) {
        if (/^=for autoupdater stop/ || /^# stop autoupdated section/) {
            print $out $_;
            last;
        }
    }
    while (<$in>) {
        print $out $_;
    }
    close $out;
    close $in;
}
sub update_buildtools {
    my $dump= Data::Dumper->new([\@meta],['*TAG_INFO_ARRAY'])->Indent(1)->Dump();
    $dump =~ s/^(\s*)\{/$1# autoupdated by $0 do not modify directly!\n$1\{/mg;
    return replace_block(
        "Perl/shared/inc/Sereal/BuildTools.pm",
        join "\n",
            "our (%TAG_INFO_HASH, \@TAG_INFO_ARRAY);",
            $dump,
            "\$TAG_INFO_HASH{chr \$_}= \$TAG_INFO_ARRAY[\$_] for 0 .. 127;",
            "push \@EXPORT_OK, qw(%TAG_INFO_HASH \@TAG_INFO_ARRAY);",
    )
}
sub update_srl_decoder_h {
    replace_block("Perl/Decoder/srl_decoder.h",
        join("\n",
            "* NOTE this section is autoupdated by $0",
            "*/",
            "static const char * const tag_name[] = {",
            ( map {
                my $str= Data::Dumper::qquote(chr($_));
                if ($str=~/^"\\[0-9]+"\z/) { $str="";}
                sprintf qq(\t%-*s /* %-4s %3d 0x%02x 0b%08b */),
                    $max_name_length+3, qq("$value_to_name_expanded{$_}") . ($_==127 ? " " : ","), $str, $_, $_, $_
            } 0 .. 127 ),
            "};",
            "/*",
            "* NOTE the above section is auto-updated by $0",
        )
    )
}

sub update_JavaSerealHeader {
    my $declarations = "* NOTE this section is autoupdated by $0 */\n";

    for my $name (sort { $name_to_value{$a} <=> $name_to_value{$b} } keys %name_to_value) {
        my $byte = $name_to_value{$name};
        my $decl = sprintf("static final byte SRL_HDR_%-*s = (byte) %3d;", $max_name_length, $name, $byte);
        $declarations .= sprintf("\t%s /* %3d 0x%02x 0b%08b %s */\n",
            $decl, $byte, $byte, $byte, $value_to_comment_expanded{$byte}||"");
    }

    $declarations .= "/*\n* NOTE the above section is auto-updated by $0";

    replace_block("Java/src/com/booking/sereal/SerealHeader.java", $declarations);

}

sub update_table {
    replace_block($_[0],
        join("\n",
            "",
            sprintf(qq(    %*s | %-4s | %3s | %4s | %10s | %s),
                $max_name_length,qw(Tag       Char Dec Hex  Binary     Follow  )),
            sprintf(qq(    %*s-+-%-4s-+-%3s-+-%4s-+-%10s |-%s),
                $max_name_length,"-" x $max_name_length, "-" x 4, "-" x 3, "-" x 4, "-" x 10, "-" x 40),
            ( map {
                my $str= Data::Dumper::qquote(chr($_));
                if ($str=~/^"\\[0-9]+"\z/) { $str="";}
                sprintf qq(    %-*s | %-4s | %3d | 0x%02x | 0b%08b | %s),
                    $max_name_length, $value_to_name_expanded{$_}, $str, $_, $_, $_, $value_to_comment_expanded{$_} || ""
            } 0 .. 127 ),
            "",
            "",
        )
    )
}

my $git_dir = `git rev-parse --git-dir`
    or die; # we will get a message from rev-parse iirc
chomp($git_dir);
chdir "$git_dir/.."
    or die "Failed to chdir to root of repo '$git_dir/..': $!";
read_protocol();
update_buildtools();
update_srl_decoder_h();
update_table("sereal_spec.pod");
update_table("Perl/shared/srl_protocol.h");
update_JavaSerealHeader();

